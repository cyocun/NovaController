import Foundation
import IOKit
import IOKit.serial

/// NovaStar MSD300 シリアル通信マネージャー
///
/// MSD300はSilicon Labs CP2102 USB-to-UARTブリッジを内蔵。
/// macOS上では仮想シリアルポート(/dev/tty.SLAB_USBtoUART等)として認識される。
///
/// プロトコル仕様:
/// - ボーレート: 115200, 8N1
/// - パケット: 0x55 0xAA ヘッダー + レジスタアドレスベースのRead/Write
/// - チェックサム: 全バイト合計 + 0x5555 の下位16bit
///
/// 参考: https://github.com/sarakusha/novastar
///       https://github.com/dietervansteenwegen/Novastar_MCTRL300_basic_controller
class USBManager: ObservableObject {
    static let shared = USBManager()

    // CP2102 USB-to-UART Bridge (Silicon Labs)
    private let vendorID: Int = 0x10C4
    private let productID: Int = 0xEA60

    @Published var isConnected: Bool = false
    @Published var deviceName: String = ""
    @Published var lastError: String? = nil

    private var serialPort: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var serialQueue = DispatchQueue(label: "com.novacontroller.serial", qos: .userInitiated)
    private var messageSerial: UInt8 = 0

    // シリアルポート設定
    private let baudRate: speed_t = 115200

    private init() {}

    // MARK: - レジスタアドレス

    /// MSD300 レジスタマップ（リバースエンジニアリングで判明済み）
    enum Register {
        /// 全体輝度 (0x00〜0xFF)
        static let globalBrightness: UInt32 = 0x02000001
        /// テストパターン (1=Off, 2=Red, 3=Green, 4=Blue, 5=White, 6=H-Lines, 7=V-Lines, 8=Slash, 9=Gray)
        static let testPattern: UInt32 = 0x02000101
        /// 画面幅（ポート単位）
        static let screenWidth: UInt32 = 0x02000002
        /// 画面高さ（ポート単位）
        static let screenHeight: UInt32 = 0x02000003
    }

    // MARK: - パケット構造定数

    private enum Packet {
        static let headerWrite: [UInt8] = [0x55, 0xAA]
        static let headerRead: [UInt8] = [0xAA, 0x55]
        static let sourcePC: UInt8 = 0xFE
        static let destDevice: UInt8 = 0x00
        static let deviceTypeSendingCard: UInt8 = 0x00
        static let dirRead: UInt8 = 0x00
        static let dirWrite: UInt8 = 0x01
    }

    // MARK: - 接続管理

    /// CP2102シリアルポートを検索して接続する
    func startMonitoring() {
        serialQueue.async { [weak self] in
            guard let self = self else { return }

            if let portPath = self.findCP2102Port() {
                self.openSerialPort(portPath)
            } else {
                DispatchQueue.main.async {
                    self.lastError = "MSD300が見つかりません。USBケーブルを確認してください。"
                }
                print("[USBManager] No CP2102 serial port found")
            }
        }
    }

    /// 接続を切断する
    func stopMonitoring() {
        serialQueue.async { [weak self] in
            self?.closeSerialPort()
        }
    }

    /// CP2102仮想シリアルポートをIOKitで検索する
    private func findCP2102Port() -> String? {
        var portIterator: io_iterator_t = 0
        let matchingDict = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary
        matchingDict[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &portIterator)
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(portIterator) }

        var service = IOIteratorNext(portIterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(portIterator)
            }

            // シリアルポートのパスを取得
            guard let pathCF = IORegistryEntryCreateCFProperty(
                service,
                kIOCalloutDeviceKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String else { continue }

            // CP2102のポート名パターンをチェック
            // macOS上では /dev/tty.SLAB_USBtoUART や /dev/tty.usbserial-XXXX として現れる
            if pathCF.contains("SLAB_USBtoUART") ||
               pathCF.contains("usbserial") ||
               pathCF.contains("CP2102") ||
               pathCF.contains("NovaS") {
                print("[USBManager] Found serial port: \(pathCF)")
                return pathCF
            }
        }
        return nil
    }

    /// シリアルポートを開いて設定する
    private func openSerialPort(_ path: String) {
        // O_NONBLOCK で開いてからブロッキングに戻す（macOS標準手法）
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            let err = String(cString: strerror(errno))
            DispatchQueue.main.async {
                self.lastError = "ポートを開けません: \(err)"
            }
            print("[USBManager] Failed to open \(path): \(err)")
            return
        }

        // ブロッキングモードに設定
        var flags = fcntl(fd, F_GETFL)
        flags &= ~O_NONBLOCK
        fcntl(fd, F_SETFL, flags)

        // 排他アクセス
        if ioctl(fd, TIOCEXCL) == -1 {
            print("[USBManager] Warning: Could not set exclusive access")
        }

        // termios設定: 115200 baud, 8N1
        var options = termios()
        tcgetattr(fd, &options)

        cfsetispeed(&options, baudRate)
        cfsetospeed(&options, baudRate)

        // Raw mode
        cfmakeraw(&options)

        // 8N1
        options.c_cflag |= UInt(CS8)
        options.c_cflag &= ~UInt(PARENB)
        options.c_cflag &= ~UInt(CSTOPB)

        // Enable receiver, local mode
        options.c_cflag |= UInt(CLOCAL | CREAD)

        // タイムアウト: 4秒 (VTIME = 40 * 0.1秒)
        options.c_cc.16 = 1   // VMIN
        options.c_cc.17 = 40  // VTIME

        tcsetattr(fd, TCSANOW, &options)

        // ポートバッファをフラッシュ
        tcflush(fd, TCIOFLUSH)

        serialPort = fd

        DispatchQueue.main.async {
            self.isConnected = true
            self.deviceName = "MSD300"
            self.lastError = nil
        }

        // 接続ハンドシェイクを送信
        sendConnectionCommand()

        // 受信監視の開始
        startReading()

        print("[USBManager] Connected to \(path) at \(baudRate) baud")
    }

    /// シリアルポートを閉じる
    private func closeSerialPort() {
        readSource?.cancel()
        readSource = nil

        if serialPort >= 0 {
            close(serialPort)
            serialPort = -1
        }

        DispatchQueue.main.async {
            self.isConnected = false
            self.deviceName = ""
        }
        print("[USBManager] Disconnected")
    }

    /// 受信データの非同期読み取り
    private func startReading() {
        guard serialPort >= 0 else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: serialPort, queue: serialQueue)
        source.setEventHandler { [weak self] in
            guard let self = self, self.serialPort >= 0 else { return }

            var buffer = [UInt8](repeating: 0, count: 256)
            let bytesRead = read(self.serialPort, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                self.handleResponse(data)
            } else if bytesRead == 0 {
                // EOF - デバイスが切断された
                self.closeSerialPort()
            }
        }
        source.setCancelHandler { [weak self] in
            // クリーンアップ
            self?.readSource = nil
        }
        source.resume()
        readSource = source
    }

    // MARK: - プロトコル実装

    /// NovaStar パケットを構築する
    /// - Parameters:
    ///   - isWrite: 書き込みコマンドか
    ///   - register: レジスタアドレス
    ///   - data: 書き込みデータ（読み取り時は空）
    ///   - port: ポート番号 (0-based)
    /// - Returns: 送信用パケット
    private func buildPacket(isWrite: Bool, register: UInt32, data: [UInt8] = [], port: UInt8 = 0) -> Data {
        let serial = nextSerial()
        let dataLength = UInt16(isWrite ? data.count : 0)

        var packet: [UInt8] = []

        // ヘッダー (2 bytes)
        packet.append(contentsOf: Packet.headerWrite)

        // ACK/Status (1 byte)
        packet.append(0x00)

        // シリアル番号 (1 byte)
        packet.append(serial)

        // 送信元: PC (1 byte)
        packet.append(Packet.sourcePC)

        // 送信先: デバイス (1 byte)
        packet.append(Packet.destDevice)

        // デバイスタイプ: 送信カード (1 byte)
        packet.append(Packet.deviceTypeSendingCard)

        // ポートアドレス (1 byte)
        packet.append(port)

        // ボード/RCVインデックス (2 bytes, little-endian)
        packet.append(contentsOf: isWrite ? [0xFF, 0xFF] : [0x00, 0x00])

        // I/O方向 (1 byte)
        packet.append(isWrite ? Packet.dirWrite : Packet.dirRead)

        // 予約 (1 byte)
        packet.append(0x00)

        // レジスタアドレス (4 bytes, little-endian)
        packet.append(UInt8(register & 0xFF))
        packet.append(UInt8((register >> 8) & 0xFF))
        packet.append(UInt8((register >> 16) & 0xFF))
        packet.append(UInt8((register >> 24) & 0xFF))

        // データ長 (2 bytes, little-endian)
        packet.append(UInt8(dataLength & 0xFF))
        packet.append(UInt8((dataLength >> 8) & 0xFF))

        // データペイロード
        if isWrite {
            packet.append(contentsOf: data)
        }

        // チェックサム計算: offset 2から末尾までの合計 + 0x5555
        let checksumBytes = Array(packet[2...])
        let sum = checksumBytes.reduce(UInt32(0x5555)) { $0 + UInt32($1) }
        packet.append(UInt8(sum & 0xFF))         // SUM_L
        packet.append(UInt8((sum >> 8) & 0xFF))  // SUM_H

        return Data(packet)
    }

    /// メッセージシリアル番号をインクリメントして返す
    private func nextSerial() -> UInt8 {
        messageSerial &+= 1
        return messageSerial
    }

    /// 接続ハンドシェイクコマンドを送信
    private func sendConnectionCommand() {
        // 接続確認: デバイスタイプの読み取り（レジスタ 0x00000000）
        let packet = buildPacket(isWrite: false, register: 0x00000000)
        sendRaw(packet)
        print("[USBManager] Connection handshake sent")
    }

    /// レスポンスを処理する
    private func handleResponse(_ data: Data) {
        guard data.count >= 2 else { return }

        let bytes = [UInt8](data)
        if bytes[0] == 0xAA && bytes[1] == 0x55 {
            // 正常レスポンス
            if data.count >= 3 {
                let status = bytes[2]
                switch status {
                case 0: print("[USBManager] Response OK (serial: \(data.count >= 4 ? bytes[3] : 0))")
                case 1: print("[USBManager] Response: Timeout")
                case 2: print("[USBManager] Response: Request CRC error")
                case 3: print("[USBManager] Response: Response CRC error")
                case 4: print("[USBManager] Response: Invalid command")
                default: print("[USBManager] Response: Unknown status \(status)")
                }
            }
        } else {
            print("[USBManager] Unexpected data: \(bytes.prefix(10).map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
    }

    // MARK: - 公開API

    /// 全体輝度を設定する (0〜100% → 0x00〜0xFF)
    /// - Parameter brightness: 輝度値 (0〜100)
    func setBrightness(_ brightness: Int) {
        let clamped = max(0, min(100, brightness))
        let value = UInt8(Double(clamped) / 100.0 * 255.0)

        let packet = buildPacket(
            isWrite: true,
            register: Register.globalBrightness,
            data: [value]
        )
        sendRaw(packet)
        print("[USBManager] setBrightness: \(clamped)% (0x\(String(format: "%02X", value)))")
    }

    /// 現在の輝度を読み取る
    func readBrightness() {
        let packet = buildPacket(
            isWrite: false,
            register: Register.globalBrightness
        )
        sendRaw(packet)
        print("[USBManager] readBrightness requested")
    }

    /// テストパターンを設定する
    /// - Parameter pattern: パターン番号 (1=Off, 2=Red, 3=Green, 4=Blue, 5=White, 6=H-Lines, 7=V-Lines, 8=Slash, 9=Gray)
    func setTestPattern(_ pattern: Int) {
        let clamped = UInt8(max(1, min(9, pattern)))
        let packet = buildPacket(
            isWrite: true,
            register: Register.testPattern,
            data: [clamped]
        )
        sendRaw(packet)
        print("[USBManager] setTestPattern: \(clamped)")
    }

    /// レイアウト設定を送信する
    func setLayout(columns: Int, rows: Int, cabinetWidth: Int, cabinetHeight: Int, enabled: Set<CabinetPosition>) {
        let totalWidth = columns * cabinetWidth
        let totalHeight = rows * cabinetHeight

        // 画面幅を設定
        let widthBytes = withUnsafeBytes(of: UInt16(totalWidth).littleEndian) { Array($0) }
        let widthPacket = buildPacket(
            isWrite: true,
            register: Register.screenWidth,
            data: widthBytes
        )
        sendRaw(widthPacket)

        // 画面高さを設定
        let heightBytes = withUnsafeBytes(of: UInt16(totalHeight).littleEndian) { Array($0) }
        let heightPacket = buildPacket(
            isWrite: true,
            register: Register.screenHeight,
            data: heightBytes
        )
        sendRaw(heightPacket)

        print("[USBManager] setLayout: \(totalWidth)x\(totalHeight)px (\(columns)x\(rows) cabinets, \(enabled.count) enabled)")
    }

    /// レジスタに任意の値を書き込む（上級者向け）
    func writeRegister(_ register: UInt32, data: [UInt8], port: UInt8 = 0) {
        let packet = buildPacket(isWrite: true, register: register, data: data, port: port)
        sendRaw(packet)
    }

    /// レジスタの値を読み取る（上級者向け）
    func readRegister(_ register: UInt32, port: UInt8 = 0) {
        let packet = buildPacket(isWrite: false, register: register, port: port)
        sendRaw(packet)
    }

    // MARK: - 低レベル送信

    /// シリアルポートにデータを書き込む
    private func sendRaw(_ data: Data) {
        serialQueue.async { [weak self] in
            guard let self = self, self.serialPort >= 0 else {
                print("[USBManager] Not connected, command dropped")
                return
            }

            let bytes = [UInt8](data)
            let written = write(self.serialPort, bytes, bytes.count)

            if written < 0 {
                let err = String(cString: strerror(errno))
                print("[USBManager] Write error: \(err)")
                DispatchQueue.main.async {
                    self.lastError = "送信エラー: \(err)"
                }
            } else {
                print("[USBManager] Sent \(written) bytes: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
        }
    }
}
