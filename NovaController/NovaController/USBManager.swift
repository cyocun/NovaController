import Foundation
import IOKit
import IOKit.serial

/// NovaStar MSD300 シリアル通信マネージャー
///
/// MSD300はSilicon Labs CP210x USB-to-UARTブリッジを内蔵。
/// macOS上では仮想シリアルポート(/dev/tty.SLAB_USBtoUART等)として認識される。
///
/// プロトコル仕様 (USBPcapキャプチャにより確認済み):
/// - ボーレート: 115200, 8N1, フロー制御なし
/// - パケット: 0x55 0xAA ヘッダー + 2バイトシーケンス番号 + レジスタベースR/W
/// - チェックサム: ヘッダ後の全バイト合計 + 0x5555、リトルエンディアン格納
///
/// 参考: https://github.com/sarakusha/novastar
///       https://github.com/dietervansteenwegen/Novastar_MCTRL300_basic_controller
class USBManager: ObservableObject {
    static let shared = USBManager()

    // CP210x USB-to-UART Bridge (Silicon Labs)
    private let vendorID: Int = 0x10C4
    private let productID: Int = 0xEA60

    @Published var isConnected: Bool = false
    @Published var deviceName: String = ""
    @Published var lastError: String? = nil

    private var serialPort: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var serialQueue = DispatchQueue(label: "com.novacontroller.serial", qos: .userInitiated)
    private var messageSerial: UInt16 = 0

    // シリアルポート設定 (USBPcapキャプチャで確認済み)
    private let baudRate: speed_t = 115200

    private init() {}

    // MARK: - レジスタアドレス (キャプチャにより確認済み)

    /// MSD300 レジスタマップ
    enum Register {
        /// 全体輝度 (0x00〜0xFF) — キャプチャで確認済み
        static let globalBrightness: UInt32 = 0x02000001
        /// RGB個別輝度 (4バイト: R, G, B, 0x00) — キャプチャ確認: 輝度変更時 F0,F0,F0,00
        static let rgbBrightness: UInt32 = 0x020001E3
        /// テストパターン
        static let testPattern: UInt32 = 0x02000101
        /// 画面幅（ピクセル単位）
        static let screenWidth: UInt32 = 0x02000002
        /// 画面高さ（ピクセル単位）
        static let screenHeight: UInt32 = 0x02000003
        /// スキャン方向 — layout3.pcapで確認
        static let scanDirection: UInt32 = 0x01000088
    }

    // MARK: - パケット構造定数 (キャプチャにより確認済み)

    private enum Packet {
        /// 送信パケット (PC→device) の先頭2バイト
        static let headerWrite: [UInt8] = [0x55, 0xAA]
        /// 受信パケット (device→PC) の先頭2バイト
        static let headerResponse: [UInt8] = [0xAA, 0x55]
        /// 送信元: PC
        static let sourcePC: UInt8 = 0xFE
        /// 送信先: 送信カード (MSD300本体)
        static let destSendingCard: UInt8 = 0x00
        /// 送信先: 受信カード (レイアウト設定で使用)
        static let destReceivingCard: UInt8 = 0xFF
        /// デバイスタイプ: 受信カード
        static let deviceTypeReceivingCard: UInt8 = 0x01
        /// 全ポート指定
        static let portAll: UInt8 = 0xFF
        /// I/O方向
        static let dirRead: UInt8 = 0x00
        static let dirWrite: UInt8 = 0x01
    }

    // MARK: - レイアウトプリセット

    /// キャプチャ検証済みのレイアウトパターン
    ///
    /// NovaLCT で実機キャプチャした 3 パターンを固定 preset として提供する。
    /// 他のパターンが必要になった場合は再キャプチャして case を追加する。
    enum LayoutPreset: String, CaseIterable, Identifiable {
        case fourByOneLTR = "4×1 左→右"
        case fourByOneRTL = "4×1 右→左"
        case twoByFourSerpentine = "2×4 S字"

        var id: String { rawValue }

        var columns: Int {
            switch self {
            case .fourByOneLTR, .fourByOneRTL: return 4
            case .twoByFourSerpentine: return 2
            }
        }

        var rows: Int {
            switch self {
            case .fourByOneLTR, .fourByOneRTL: return 1
            case .twoByFourSerpentine: return 4
            }
        }

        /// キャプチャ検証済みのキャビネット寸法 (128×128 固定)
        var cabinetWidth: Int { 128 }
        var cabinetHeight: Int { 128 }

        var scanDirection: ScanDirection {
            switch self {
            case .fourByOneLTR: return .leftToRight
            case .fourByOneRTL: return .rightToLeft
            case .twoByFourSerpentine: return .serpentine
            }
        }
    }

    /// プリセット内部のスキャン方向（外部公開はせず LayoutPreset 経由で指定）
    enum ScanDirection {
        case leftToRight
        case rightToLeft
        case serpentine
    }


    // MARK: - 接続管理

    /// CP210xシリアルポートを検索して接続する
    func startMonitoring() {
        serialQueue.async { [weak self] in
            guard let self = self else { return }

            if let portPath = self.findCP210xPort() {
                self.openSerialPort(portPath)
            } else {
                DispatchQueue.main.async {
                    self.lastError = "MSD300が見つかりません。USBケーブルを確認してください。"
                }
                print("[USBManager] No CP210x serial port found")
            }
        }
    }

    /// 接続を切断する
    func stopMonitoring() {
        serialQueue.async { [weak self] in
            self?.closeSerialPort()
        }
    }

    /// CP210x仮想シリアルポートをIOKitで検索する
    private func findCP210xPort() -> String? {
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

            guard let pathCF = IORegistryEntryCreateCFProperty(
                service,
                kIOCalloutDeviceKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String else { continue }

            // CP210xのポート名パターン
            // macOS: /dev/tty.SLAB_USBtoUART, /dev/tty.usbserial-XXXX
            if pathCF.contains("SLAB_USBtoUART") ||
               pathCF.contains("usbserial") ||
               pathCF.contains("CP210") ||
               pathCF.contains("NovaS") {
                print("[USBManager] Found serial port: \(pathCF)")
                return pathCF
            }
        }
        return nil
    }

    /// シリアルポートを開いて設定する
    private func openSerialPort(_ path: String) {
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
        _ = fcntl(fd, F_SETFL, flags)

        // 排他アクセス
        if ioctl(fd, TIOCEXCL) == -1 {
            print("[USBManager] Warning: Could not set exclusive access")
        }

        // termios: 115200 baud, 8N1, フロー制御なし (キャプチャ確認済み)
        var options = termios()
        tcgetattr(fd, &options)
        cfsetispeed(&options, baudRate)
        cfsetospeed(&options, baudRate)
        cfmakeraw(&options)
        options.c_cflag |= UInt(CS8)
        options.c_cflag &= ~UInt(PARENB)
        options.c_cflag &= ~UInt(CSTOPB)
        options.c_cflag |= UInt(CLOCAL | CREAD)
        options.c_cc.16 = 1   // VMIN
        options.c_cc.17 = 40  // VTIME (4秒)
        tcsetattr(fd, TCSANOW, &options)
        tcflush(fd, TCIOFLUSH)

        serialPort = fd

        DispatchQueue.main.async {
            self.isConnected = true
            self.deviceName = "MSD300"
            self.lastError = nil
        }

        sendConnectionCommand()
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

            var buffer = [UInt8](repeating: 0, count: 512)
            let bytesRead = read(self.serialPort, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                self.handleResponse(data)
            } else if bytesRead == 0 {
                self.closeSerialPort()
            }
        }
        source.setCancelHandler { [weak self] in
            self?.readSource = nil
        }
        source.resume()
        readSource = source
    }

    // MARK: - プロトコル実装

    /// NovaStar パケットを構築する (キャプチャ確認済みフォーマット)
    ///
    /// パケット構造:
    /// ```
    /// 55 AA [seq_hi seq_lo] FE [dest] [devtype] [port] [board_hi board_lo]
    ///       [dir] [00] [reg LE 4B] [len LE 2B] [data...] [chk_lo chk_hi]
    /// ```
    private func buildPacket(
        isWrite: Bool,
        register: UInt32,
        data: [UInt8] = [],
        dest: UInt8 = Packet.destSendingCard,
        port: UInt8 = Packet.portAll,
        boardIndex: UInt16 = 0xFFFF,
        reserved: UInt8 = 0x00,
        deviceType: UInt8? = nil,
        lengthOverride: UInt16? = nil
    ) -> Data {
        let serial = nextSerial()
        // lengthOverride は「data は空だが len フィールドは非0」のような読み取り要求用
        let dataLength = lengthOverride ?? UInt16(isWrite ? data.count : 0)

        // デバイスタイプ: 明示指定がなければ board=0x0000→0x00、それ以外→0x01
        // パーカード設定(Section 4)ではboard=0x0000でも0x01が必要なため、明示指定で対応
        // キャプチャ検証済み: L→R board=0のパーカード設定で deviceType=0x01 を確認
        let devType: UInt8 = deviceType ?? ((boardIndex == 0x0000) ? 0x00 : Packet.deviceTypeReceivingCard)

        var packet: [UInt8] = []

        // ヘッダー (2 bytes)
        packet.append(contentsOf: Packet.headerWrite)

        // シーケンス番号 (2 bytes) — キャプチャ: 00 E8, 00 FA 等
        packet.append(UInt8((serial >> 8) & 0xFF))
        packet.append(UInt8(serial & 0xFF))

        // 送信元: PC
        packet.append(Packet.sourcePC)

        // 送信先: 0x00=送信カード(MSD300), 0xFF=受信カード
        packet.append(dest)

        // デバイスタイプ: 0x00=送信カード, 0x01=受信カード
        packet.append(devType)

        // ポートアドレス
        packet.append(port)

        // ボードインデックス (2 bytes, little-endian)
        // キャプチャ検証: board=3 → 03 00 (LE)
        packet.append(UInt8(boardIndex & 0xFF))
        packet.append(UInt8((boardIndex >> 8) & 0xFF))

        // I/O方向
        packet.append(isWrite ? Packet.dirWrite : Packet.dirRead)

        // 予約
        packet.append(reserved)

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

        // チェックサム: 0x5555 + ヘッダ(55 AA)後の全バイト合計, LE格納
        // (5パケット検証済み)
        let checksumBytes = Array(packet[2...])
        let sum = checksumBytes.reduce(UInt32(0x5555)) { $0 + UInt32($1) }
        packet.append(UInt8(sum & 0xFF))         // chk_lo
        packet.append(UInt8((sum >> 8) & 0xFF))  // chk_hi

        return Data(packet)
    }

    /// メッセージシーケンス番号をインクリメント
    private func nextSerial() -> UInt16 {
        messageSerial &+= 1
        return messageSerial
    }

    /// 接続ハンドシェイク
    private func sendConnectionCommand() {
        let packet = buildPacket(isWrite: false, register: 0x00000000)
        sendRaw(packet)
        print("[USBManager] Connection handshake sent")
    }

    /// レスポンスを処理
    ///
    /// 応答フォーマット (キャプチャ確認済み, 20バイト以上):
    /// `AA 55 [seq_hi seq_lo] 00 FE [devtype] [port] [board_lo board_hi]`
    /// `[dir] [reserved] [reg LE 4B] [len LE 2B] [data...] [chk_lo chk_hi]`
    private func handleResponse(_ data: Data) {
        guard data.count >= 2 else { return }
        let bytes = [UInt8](data)

        // 応答ヘッダ (AA 55) 以外は不明データとしてログのみ
        guard bytes[0] == Packet.headerResponse[0], bytes[1] == Packet.headerResponse[1] else {
            print("[USBManager] Unexpected data: \(bytes.prefix(10).map { String(format: "%02X", $0) }.joined(separator: " "))")
            return
        }

        guard bytes.count >= 20 else {
            print("[USBManager] Response (short, \(bytes.count)B)")
            return
        }

        let seq = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        let reg = UInt32(bytes[12]) | (UInt32(bytes[13]) << 8) | (UInt32(bytes[14]) << 16) | (UInt32(bytes[15]) << 24)
        let len = Int(bytes[16]) | (Int(bytes[17]) << 8)
        let payloadEnd = min(18 + len, bytes.count - 2)
        let payload = Array(bytes[18..<payloadEnd])

        if reg == Register.globalBrightness, let raw = payload.first {
            let percent = Int((Double(raw) / 255.0 * 100.0).rounded())
            print("[USBManager] Brightness response: 0x\(String(format: "%02X", raw)) (\(percent)%) seq=0x\(String(format: "%04X", seq))")
        } else {
            print("[USBManager] Response reg=0x\(String(format: "%08X", reg)) len=\(len) seq=0x\(String(format: "%04X", seq))")
        }
    }

    // MARK: - 公開API: 輝度制御 (キャプチャ検証済み)

    /// 全体輝度を設定する (0〜100% → 0x00〜0xFF)
    ///
    /// キャプチャ確認済みプロトコル:
    /// 1. globalBrightness (0x02000001) に輝度値 1バイト書き込み
    /// 2. rgbBrightness (0x020001E3) に R,G,B,0x00 の4バイト書き込み
    /// NovaLCTは毎回この2パケットをセットで送信する。
    func setBrightness(_ brightness: Int, r: UInt8 = 0xF0, g: UInt8 = 0xF0, b: UInt8 = 0xF0) {
        let clamped = max(0, min(100, brightness))
        let value = UInt8(Double(clamped) / 100.0 * 255.0)

        // パケット1: 全体輝度 (dest=0x00 送信カード宛)
        let brightnessPacket = buildPacket(
            isWrite: true,
            register: Register.globalBrightness,
            data: [value],
            dest: Packet.destSendingCard
        )
        sendRaw(brightnessPacket)

        // パケット2: RGB個別輝度 (毎回 F0 F0 F0 00 をセットで送信)
        let rgbPacket = buildPacket(
            isWrite: true,
            register: Register.rgbBrightness,
            data: [r, g, b, 0x00],
            dest: Packet.destSendingCard
        )
        sendRaw(rgbPacket)

        print("[USBManager] setBrightness: \(clamped)% (0x\(String(format: "%02X", value))), RGB=(\(r),\(g),\(b))")
    }

    /// 現在の輝度を読み取る
    func readBrightness() {
        let packet = buildPacket(
            isWrite: false,
            register: Register.globalBrightness,
            dest: Packet.destSendingCard
        )
        sendRaw(packet)
        print("[USBManager] readBrightness requested")
    }

    // MARK: - 公開API: テストパターン

    /// テストパターンを設定する
    func setTestPattern(_ pattern: Int) {
        let clamped = UInt8(max(1, min(9, pattern)))
        let packet = buildPacket(
            isWrite: true,
            register: Register.testPattern,
            data: [clamped],
            dest: Packet.destSendingCard
        )
        sendRaw(packet)
        print("[USBManager] setTestPattern: \(clamped)")
    }

    // MARK: - 公開API: 受信カードリセット

    /// 受信カードを 4×1 左→右プリセットで再適用する (不調時の復旧用)
    func resetReceivingCards() {
        print("[USBManager] Resetting receiving cards with 4×1 L→R preset")
        setLayout(preset: .fourByOneLTR)
    }

    // MARK: - 公開API: レイアウト設定

    /// プリセットに基づきレイアウト設定のフルシーケンスを送信する
    ///
    /// キャプチャ検証済みの 3 パターンのみ対応。シーケンスは以下:
    /// 1. 初期化 (2 cmd): 受信カード初期化
    /// 2. グローバル設定 (12 cmd): 画面サイズ、カード数等
    /// 2.5. マッピング直前の特殊コマンド (1 cmd): reg=0x02020020
    /// 3. マッピングテーブル (16 cmd): 16ブロック×256バイト
    /// 4. パーカード設定 (1 + cards×2 cmd): 各受信カードのサイズ設定
    /// 5. コミット (3 cmd): 設定適用
    func setLayout(preset: LayoutPreset) {
        let columns = preset.columns
        let rows = preset.rows
        let cabinetWidth = preset.cabinetWidth
        let cabinetHeight = preset.cabinetHeight
        let scanDirection = preset.scanDirection
        let totalWidth = columns * cabinetWidth
        let totalHeight = rows * cabinetHeight
        let totalCards = columns * rows

        serialQueue.async { [weak self] in
            guard let self = self, self.serialPort >= 0 else {
                print("[USBManager] Not connected")
                return
            }

            print("[USBManager] setLayout: preset=\(preset.rawValue) (\(columns)x\(rows) = \(totalWidth)x\(totalHeight)px)")

            let widthLE = self.uint16LE(UInt16(totalWidth))
            let heightLE = self.uint16LE(UInt16(totalHeight))

            // === Section 1: 初期化 (dest=0xFF 受信カード) ===
            self.sendCmd(dest: 0xFF, port: 0x00, board: 0x0000, reg: 0x02000018, data: [0x00])
            self.sendCmd(dest: 0xFF, port: 0x00, board: 0x0000, reg: 0x02000019, data: [0x00])

            // === Section 2: グローバル設定 (dest=0x00 送信カード) ===
            self.sendCmd(dest: 0x00, reg: 0x020000F0, data: [0x00])
            self.sendCmd(dest: 0x00, reg: 0x02000028, data: [0x00, 0x00])  // offset X area1
            self.sendCmd(dest: 0x00, reg: 0x0200002A, data: [0x00, 0x00])  // offset Y area1
            self.sendCmd(dest: 0x00, reg: 0x02000024, data: widthLE)       // width area1
            self.sendCmd(dest: 0x00, reg: 0x02000026, data: heightLE)      // height area1
            self.sendCmd(dest: 0x00, reg: 0x0200002C, data: widthLE)       // stride area1
            self.sendCmd(dest: 0x00, reg: 0x02000055, data: [0x00, 0x00])  // offset X area3
            self.sendCmd(dest: 0x00, reg: 0x02000057, data: [0x00, 0x00])  // offset Y area3
            self.sendCmd(dest: 0x00, reg: 0x02000051, data: widthLE)       // width area3
            self.sendCmd(dest: 0x00, reg: 0x02000053, data: heightLE)      // height area3
            self.sendCmd(dest: 0x00, reg: 0x03100000, data: self.uint16LE(UInt16(totalCards)))  // card count
            self.sendCmd(dest: 0x00, reg: 0x02000050, data: [0x00])

            // === Section 2.5: マッピングテーブル直前の特殊コマンド (キャプチャ line 21) ===
            // reg=0x02020020, dir=write, len=0x0040, data=empty の変則パケット。
            // NovaLCT がマッピング書き込み前に必ず送っているため再現する。
            self.sendCmd(dest: 0x00, port: 0x00, board: 0x0000,
                         reg: 0x02020020, data: [],
                         lengthOverride: 0x0040)

            // === Section 3: マッピングテーブル (16ブロック) ===
            let mappingBlock = self.buildMappingBlock(
                columns: columns, rows: rows,
                cabinetWidth: cabinetWidth, cabinetHeight: cabinetHeight,
                scanDirection: scanDirection
            )
            for blockIndex in 0..<16 {
                let regAddr: UInt32 = 0x03000000 + UInt32(blockIndex) * 0x100
                self.sendCmd(dest: 0x00, reg: regAddr, data: mappingBlock)
            }

            // === Section 4: パーカード設定 ===
            // パーカード設定は全て deviceType=0x01 (受信カード) — キャプチャで確認済み
            // board=0x0000 のカードでも deviceType=0x01 であることに注意
            let rcvType = Packet.deviceTypeReceivingCard

            // 全ボードリセット
            self.sendCmd(dest: 0x00, port: 0x00, board: 0xFFFF, reg: 0x0200009A, data: [0x00], deviceType: rcvType)

            // 各カードのサイズを設定
            let order = self.boardOrder(columns: columns, rows: rows,
                                        cabinetWidth: cabinetWidth, cabinetHeight: cabinetHeight,
                                        scanDirection: scanDirection)
            for boardIndex in order {
                let wLE = self.uint16LE(UInt16(cabinetWidth))
                let hLE = self.uint16LE(UInt16(cabinetHeight))
                self.sendCmd(dest: 0x00, port: 0x00, board: UInt16(boardIndex), reg: 0x02000017, data: wLE, deviceType: rcvType)
                self.sendCmd(dest: 0x00, port: 0x00, board: UInt16(boardIndex), reg: 0x02000019, data: hLE, deviceType: rcvType)
            }

            // === Section 5: コミット (キャプチャ検証済み) ===
            self.sendCmd(dest: 0xFF, port: 0x00, board: 0x0000, reg: 0x020000AE, data: [0x01])
            self.sendCmd(dest: 0xFF, port: 0xFF, board: 0xFFFF, reg: 0x01000012, data: [0xAA], reserved: 0x08)
            self.sendCmd(dest: 0x00, reg: 0x020001EC, data: self.uint16LE(UInt16(totalWidth)) + self.uint16LE(UInt16(totalHeight)))

            print("[USBManager] Layout applied: \(totalWidth)x\(totalHeight)px")
        }
    }

    // MARK: - レイアウト ヘルパー

    /// マッピングテーブルブロック (256バイト) を生成する
    ///
    /// キャプチャ解析結果:
    /// - 各エントリは4バイト: [X_LE16][Y_LE16] — カード1枚の画面上座標
    /// - エントリ列をパターンとして256バイトになるまで繰り返し
    /// - スキャン方向によって座標の並び順が異なる
    private func buildMappingBlock(columns: Int, rows: Int, cabinetWidth: Int, cabinetHeight: Int,
                                   scanDirection: ScanDirection) -> [UInt8] {
        let coords = cardCoordinates(columns: columns, rows: rows,
                                     cabinetWidth: cabinetWidth, cabinetHeight: cabinetHeight,
                                     scanDirection: scanDirection)

        // 各カード座標を4バイトエントリとして書き出す
        var pattern = [UInt8]()
        for (x, y) in coords {
            pattern.append(contentsOf: uint16LE(UInt16(x)))
            pattern.append(contentsOf: uint16LE(UInt16(y)))
        }

        // パターンを繰り返して256バイトに充填 (空パターン時は 0 埋めにフォールバック)
        guard !pattern.isEmpty else {
            return Array(repeating: 0x00, count: 256)
        }
        var block = [UInt8]()
        while block.count < 256 {
            block.append(contentsOf: pattern)
        }
        return Array(block.prefix(256))
    }

    /// スキャン方向に基づくカード座標リストを生成する
    ///
    /// 戻り値: 各ボードインデックス順の (X, Y) ピクセル座標
    /// ボード0, 1, 2, ... の順に、画面上のどの位置に表示するかを返す
    private func cardCoordinates(columns: Int, rows: Int, cabinetWidth: Int, cabinetHeight: Int,
                                 scanDirection: ScanDirection) -> [(x: Int, y: Int)] {
        let totalCards = columns * rows
        var coords = [(x: Int, y: Int)]()

        switch scanDirection {
        case .leftToRight:
            // ボード0が左上、左→右に進み、次の行へ
            for i in 0..<totalCards {
                let col = i % columns
                let row = i / columns
                coords.append((col * cabinetWidth, row * cabinetHeight))
            }
        case .rightToLeft:
            // ボード0が右上、右→左に進み、次の行へ
            for i in 0..<totalCards {
                let col = i % columns
                let row = i / columns
                coords.append(((columns - 1 - col) * cabinetWidth, row * cabinetHeight))
            }
        case .serpentine:
            // S字パターン: 偶数列は下→上、奇数列は上→下 (キャプチャで確認)
            for col in 0..<columns {
                if col % 2 == 0 {
                    for row in stride(from: rows - 1, through: 0, by: -1) {
                        coords.append((col * cabinetWidth, row * cabinetHeight))
                    }
                } else {
                    for row in 0..<rows {
                        coords.append((col * cabinetWidth, row * cabinetHeight))
                    }
                }
            }
        }

        return coords
    }

    /// パーカード設定の送信順序を返す
    ///
    /// cardCoordinates が出力する (x, y) を画面上の col-major 走査順で並べ替え、
    /// 該当する board index を返す。キャプチャ実測の送信順に完全一致する:
    /// - 4×1 L→R: [0, 1, 2, 3]
    /// - 4×1 R→L: [3, 2, 1, 0]
    /// - 2×4 S字: [3, 2, 1, 0, 4, 5, 6, 7]
    private func boardOrder(columns: Int, rows: Int,
                            cabinetWidth: Int, cabinetHeight: Int,
                            scanDirection: ScanDirection) -> [Int] {
        let coords = cardCoordinates(columns: columns, rows: rows,
                                     cabinetWidth: cabinetWidth, cabinetHeight: cabinetHeight,
                                     scanDirection: scanDirection)
        // (col, row) key → board index
        var boardByPos = [Int: Int]()
        for (i, c) in coords.enumerated() {
            let col = c.x / cabinetWidth
            let row = c.y / cabinetHeight
            boardByPos[row * columns + col] = i
        }
        var order = [Int]()
        for col in 0..<columns {
            for row in 0..<rows {
                if let b = boardByPos[row * columns + col] {
                    order.append(b)
                }
            }
        }
        return order
    }

    /// UInt16をリトルエンディアンのバイト配列に変換
    private func uint16LE(_ value: UInt16) -> [UInt8] {
        return withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    /// 1コマンドを構築して送信する (コマンド間5ms待機付き)
    private func sendCmd(dest: UInt8 = 0x00, port: UInt8 = 0x00, board: UInt16 = 0x0000, reg: UInt32, data: [UInt8], reserved: UInt8 = 0x00, deviceType: UInt8? = nil, lengthOverride: UInt16? = nil, isWrite: Bool = true) {
        let packet = buildPacket(isWrite: isWrite, register: reg, data: data, dest: dest, port: port, boardIndex: board, reserved: reserved, deviceType: deviceType, lengthOverride: lengthOverride)
        let bytes = [UInt8](packet)
        let written = write(self.serialPort, bytes, bytes.count)
        if written < 0 {
            print("[USBManager] Write error: \(String(cString: strerror(errno)))")
        }
        usleep(5000) // 5ms間隔
    }

    // MARK: - 公開API: 汎用レジスタアクセス

    /// レジスタに任意の値を書き込む
    func writeRegister(_ register: UInt32, data: [UInt8], dest: UInt8 = Packet.destSendingCard, port: UInt8 = Packet.portAll) {
        let packet = buildPacket(isWrite: true, register: register, data: data, dest: dest, port: port)
        sendRaw(packet)
    }

    /// レジスタの値を読み取る
    func readRegister(_ register: UInt32, dest: UInt8 = Packet.destSendingCard, port: UInt8 = Packet.portAll) {
        let packet = buildPacket(isWrite: false, register: register, dest: dest, port: port)
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
