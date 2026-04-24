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
@Observable
class USBManager {
    static let shared = USBManager()

    // CP210x USB-to-UART Bridge (Silicon Labs)
    @ObservationIgnored private let vendorID: Int = 0x10C4
    @ObservationIgnored private let productID: Int = 0xEA60

    // UI が購読する状態 (Observation で自動追跡される)
    var isConnected: Bool = false
    var deviceName: String = ""
    var lastError: String? = nil

    /// 実機から読み取った最新の全体輝度 (0–100%)。未読なら nil
    var currentBrightness: Int? = nil
    /// 実機から読み取った最新の RGB 輝度 (各 0–255)。未読なら nil
    var currentRGB: RGBLevel? = nil
    /// 直近に送信したテストパターン (UI 同期用)
    var currentPattern: TestPattern = .normal
    /// 直近に送信したディスプレイモード (UI 同期用)
    var currentDisplayMode: DisplayMode = .normal
    /// 接続直後に実機から読み取ったハードウェア情報。未取得なら nil
    var connectedDeviceInfo: DeviceInfo? = nil

    // 内部状態は UI 追跡対象外
    @ObservationIgnored private var serialPort: Int32 = -1
    @ObservationIgnored private var readSource: DispatchSourceRead?
    @ObservationIgnored private var serialQueue = DispatchQueue(label: "com.novacontroller.serial", qos: .userInitiated)
    @ObservationIgnored private var messageSerial: UInt16 = 0
    @ObservationIgnored private let serialLock = NSLock()
    /// UART は本来ストリームなので、複数応答が連結/分割されて届く可能性がある。
    /// ヘッダ AA 55 + 長さフィールドで 1 パケット単位に切り出すための受信バッファ。
    /// `[UInt8]` で持つ理由: `Data.removeFirst(n)` は内部 startIndex を進めるだけで
    /// その後 `data[0]` で範囲外アクセス → クラッシュするため。Array なら 0 ベース安全。
    @ObservationIgnored private var rxBuffer = [UInt8]()

    /// 応答待ちの continuation (シーケンス番号キー)
    @ObservationIgnored private var pendingReads: [UInt16: CheckedContinuation<Data?, Never>] = [:]
    @ObservationIgnored private let pendingLock = NSLock()

    // シリアルポート設定 (USBPcapキャプチャで確認済み)
    @ObservationIgnored private let baudRate: speed_t = 115200

    private init() {}

    // MARK: - レジスタアドレス (キャプチャにより確認済み)

    /// MSD300 レジスタマップ
    ///
    /// アドレスはキャプチャで確認済み。命名は sarakusha/novastar
    /// (NovaLCT の .NET バイナリをデコンパイルした TypeScript ライブラリ) の
    /// 公式 AddressMapping と突き合わせて確定。
    enum Register {
        /// 全体輝度 (0x00〜0xFF) 1バイト
        /// 公式名: `GlobalBrightnessAddr`
        static let globalBrightness: UInt32 = 0x02000001
        /// RGB+V 個別輝度 4バイト (R, G, B, V=0x00)
        /// 公式名: `FourSystemAdaptiveBrightnessAddr`
        /// 輝度変更時のキャプチャでは F0,F0,F0,00 を観測
        static let rgbBrightness: UInt32 = 0x020001E3
        /// テストパターン
        static let testPattern: UInt32 = 0x02000101
        /// ブラックアウト (0xFF=黒 / 0x00=解除) 1バイト
        /// companion-module CHOICES_DISPLAYMODE_MCTRL のパケットから確定
        static let blackout: UInt32 = 0x02000100
        /// フリーズ (0xFF=静止 / 0x00=解除) 1バイト
        /// companion-module CHOICES_DISPLAYMODE_MCTRL のパケットから確定
        static let freeze: UInt32 = 0x02000102
        /// 画面幅（ピクセル単位）
        static let screenWidth: UInt32 = 0x02000002
        /// 画面高さ（ピクセル単位）
        static let screenHeight: UInt32 = 0x02000003
        /// スキャン方向関連 (layout3.pcapで確認)
        /// 公式名: `ScannerMappingAddr` (受信カード側)
        static let scanDirection: UInt32 = 0x01000088
    }

    // MARK: - テストパターン / ディスプレイモード

    /// 内蔵テストパターン
    ///
    /// `Register.testPattern (0x02000101)` に 1 バイト書き込むと受信カードが該当パターンを表示する。
    /// 値は dietervansteenwegen/Novastar_MCTRL300_basic_controller および
    /// bitfocus/companion-module-novastar-controller のキャプチャで確認済み。
    enum TestPattern: UInt8, CaseIterable, Identifiable {
        case normal     = 1  // パターン解除 (通常映像)
        case red        = 2
        case green      = 3
        case blue       = 4
        case white      = 5
        case horizontal = 6  // 横縞
        case vertical   = 7  // 縦縞
        case diagonal   = 8  // 斜線
        case grayscale  = 9

        var id: UInt8 { rawValue }

        var label: String {
            switch self {
            case .normal:     return "Off"
            case .red:        return "Red"
            case .green:      return "Green"
            case .blue:       return "Blue"
            case .white:      return "White"
            case .horizontal: return "H. Stripes"
            case .vertical:   return "V. Stripes"
            case .diagonal:   return "Diagonal"
            case .grayscale:  return "Grayscale"
            }
        }
    }

    /// 画面全体のディスプレイモード (Blackout + Freeze レジスタで制御)
    enum DisplayMode: String, CaseIterable, Identifiable {
        case normal = "Normal"
        case freeze = "Freeze"
        case black  = "Black"
        var id: String { rawValue }
    }

    /// R/G/B 各チャンネルの輝度値 (0–255)
    struct RGBLevel: Equatable {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        static let neutral = RGBLevel(r: 0xF0, g: 0xF0, b: 0xF0)
    }

    /// 接続中のコントローラから読み取ったハードウェア情報
    struct DeviceInfo: Equatable {
        /// 受信カード総数 (`Sender_NetworkInterfaceCardNumber` = `cols × rows`)
        let cardCount: Int
        /// 画面全体の幅 (px) — 0 のときは取得失敗または未設定
        let screenWidth: Int
        /// 画面全体の高さ (px)
        let screenHeight: Int
        /// コントローラ機種ID (`ReadControllerModelId`、生値)。MSD300 は固定値が返る
        let controllerModelId: UInt16?
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
        /// 注: sarakusha/novastar の DeviceTypeEnum は {Sender=1, Scanner=2, All=3} と定義しているが、
        /// MSD300 実機のキャプチャでは 0x00/0x01/0xFF を観測。Swift 側はキャプチャ準拠の値を使用する。
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
        case fourByOneLTR = "4×1 Left-to-Right"
        case fourByOneRTL = "4×1 Right-to-Left"
        case twoByFourSerpentine = "2×4 Serpentine"

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
                    self.lastError = "MSD300 not found. Please check the USB cable."
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
                self.lastError = "Failed to open port: \(err)"
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

        // 接続直後に現在の輝度を問い合わせて UI 表示に反映する
        readBrightness()
        readRGBBrightness()

        // ハードウェア情報 (カード数 / 画面サイズ / 機種ID) を非同期取得
        Task { [weak self] in
            await self?.readDeviceInfo()
        }

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

        rxBuffer.removeAll(keepingCapacity: true)

        DispatchQueue.main.async {
            self.isConnected = false
            self.deviceName = ""
            self.connectedDeviceInfo = nil
            self.currentBrightness = nil
            self.currentRGB = nil
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
        lengthOverride: UInt16? = nil,
        seq: UInt16? = nil
    ) -> Data {
        let serial = seq ?? nextSerial()
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

    /// メッセージシーケンス番号をインクリメント (スレッドセーフ)
    private func nextSerial() -> UInt16 {
        serialLock.lock()
        defer { serialLock.unlock() }
        messageSerial &+= 1
        return messageSerial
    }

    /// 接続ハンドシェイク
    private func sendConnectionCommand() {
        let packet = buildPacket(isWrite: false, register: 0x00000000)
        sendRaw(packet)
        print("[USBManager] Connection handshake sent")
    }

    /// シリアル受信データを蓄積し、完全な 1 パケットを切り出して処理する
    ///
    /// UART は本来ストリームなので、応答パケットが複数連結されたり 1 パケットが
    /// 分割されたりして届く。`rxBuffer` に蓄積し、ヘッダ `AA 55` + 長さフィールドで
    /// パケット境界を判定する。
    private func handleResponse(_ data: Data) {
        rxBuffer.append(contentsOf: data)
        while let packet = extractNextPacket() {
            processPacket(packet)
        }
    }

    /// `rxBuffer` から完全な 1 パケットを取り出す。不足ならば nil。
    private func extractNextPacket() -> Data? {
        // ヘッダ AA 55 を探す (見つからなければ末尾 1 バイトだけ残して捨てる)
        let headerIdx = findResponseHeader()
        if let idx = headerIdx, idx > 0 {
            rxBuffer.removeFirst(idx)
        } else if headerIdx == nil {
            // ヘッダ未発見: 次の AA 候補に備えて末尾 1 バイトだけ残す
            if rxBuffer.count > 1 {
                rxBuffer.removeFirst(rxBuffer.count - 1)
            }
            return nil
        }

        // ヘッダ〜長さフィールド (offset 17 まで) が揃うのを待つ
        guard rxBuffer.count >= 18 else { return nil }
        let len = Int(rxBuffer[16]) | (Int(rxBuffer[17]) << 8)
        let totalLen = 18 + len + 2  // header(18) + payload(len) + checksum(2)
        guard rxBuffer.count >= totalLen else { return nil }

        let packet = Array(rxBuffer[0..<totalLen])
        rxBuffer.removeFirst(totalLen)
        return Data(packet)
    }

    /// rxBuffer から AA 55 の開始位置を探す。見つからなければ nil。
    private func findResponseHeader() -> Int? {
        guard rxBuffer.count >= 2 else { return nil }
        for i in 0...(rxBuffer.count - 2) {
            if rxBuffer[i] == Packet.headerResponse[0],
               rxBuffer[i + 1] == Packet.headerResponse[1] {
                return i
            }
        }
        return nil
    }

    /// 完全な応答パケットを処理する
    ///
    /// 応答フォーマット (mctrl300.py / 実機ログから確定):
    /// `AA 55 [ack] [serno] FE [src] [devtype] [port] [board_lo board_hi]`
    /// `[dir] [reserved] [reg LE 4B] [len LE 2B] [data...] [chk_lo chk_hi]`
    ///
    /// 注: `bytes[2]` は ACK バイト (0x00 = 成功 / 非ゼロ = エラー)、
    /// `bytes[3]` が送信時 serno の **下位 1 バイト**。送信時 serno (UInt16) の
    /// 下位バイトでマッチングする。
    private func processPacket(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 20 else { return }

        let ack = bytes[2]
        let sernoLow = bytes[3]
        let reg = UInt32(bytes[12]) | (UInt32(bytes[13]) << 8) | (UInt32(bytes[14]) << 16) | (UInt32(bytes[15]) << 24)
        let len = Int(bytes[16]) | (Int(bytes[17]) << 8)
        let payloadEnd = min(18 + len, bytes.count - 2)
        let payload = Data(bytes[18..<payloadEnd])

        // 送信時 serno (UInt16) の下位バイトをキーに pendingReads を検索
        pendingLock.lock()
        let waitingKey = pendingReads.keys.first { UInt8($0 & 0xFF) == sernoLow }
        let waiter = waitingKey.flatMap { pendingReads.removeValue(forKey: $0) }
        pendingLock.unlock()
        if let cont = waiter {
            // ACK エラー時は payload を渡さず nil
            cont.resume(returning: ack == 0 ? payload : nil)
            return
        }

        // ACK エラー時は内部状態を上書きしない
        guard ack == 0 else {
            print("[USBManager] ⚠️ ACK error 0x\(String(format: "%02X", ack)) reg=0x\(String(format: "%08X", reg)) sernoLow=0x\(String(format: "%02X", sernoLow))")
            return
        }

        if reg == Register.globalBrightness, let raw = payload.first {
            let percent = Int((Double(raw) / 255.0 * 100.0).rounded())
            DispatchQueue.main.async { self.currentBrightness = percent }
            print("[USBManager] Brightness response: 0x\(String(format: "%02X", raw)) (\(percent)%)")
        } else if reg == Register.rgbBrightness, payload.count >= 3 {
            let level = RGBLevel(r: payload[0], g: payload[1], b: payload[2])
            DispatchQueue.main.async { self.currentRGB = level }
            print("[USBManager] RGB response: R=\(level.r) G=\(level.g) B=\(level.b)")
        } else {
            print("[USBManager] Response reg=0x\(String(format: "%08X", reg)) len=\(len)")
        }
    }

    // MARK: - 公開API: 輝度制御 (キャプチャ検証済み)

    /// 全体輝度を設定する (0〜100% → 0x00〜0xFF)
    ///
    /// キャプチャ確認済みプロトコル:
    /// 1. globalBrightness (0x02000001) に輝度値 1バイト書き込み
    /// 2. rgbBrightness (0x020001E3) に R,G,B,0x00 の4バイト書き込み
    /// NovaLCTは毎回この2パケットをセットで送信する。
    ///
    /// - Parameter board: nil の場合は全パネル (dest=送信カード, board=0xFFFF)。
    ///                    Int 指定時は該当受信カードのみ (dest=受信カード, board=指定値)。
    ///                    「色味が違うパネルだけ絞る」「特定板の白バランス補正」等の用途。
    func setBrightness(_ brightness: Int,
                       r: UInt8 = 0xF0, g: UInt8 = 0xF0, b: UInt8 = 0xF0,
                       board: UInt16? = nil) {
        let clamped = max(0, min(100, brightness))
        let value = UInt8(Double(clamped) / 100.0 * 255.0)

        let dest: UInt8 = (board == nil) ? Packet.destSendingCard : Packet.destReceivingCard
        let boardIndex: UInt16 = board ?? 0xFFFF

        // パケット1: 全体輝度
        let brightnessPacket = buildPacket(
            isWrite: true,
            register: Register.globalBrightness,
            data: [value],
            dest: dest,
            boardIndex: boardIndex
        )
        sendRaw(brightnessPacket)

        // パケット2: RGB個別輝度 (毎回 R G B 00 をセットで送信)
        let rgbPacket = buildPacket(
            isWrite: true,
            register: Register.rgbBrightness,
            data: [r, g, b, 0x00],
            dest: dest,
            boardIndex: boardIndex
        )
        sendRaw(rgbPacket)

        let targetLabel = board.map { "board #\($0)" } ?? "all panels"
        print("[USBManager] setBrightness: \(clamped)% (0x\(String(format: "%02X", value))), RGB=(\(r),\(g),\(b)), target=\(targetLabel)")
    }

    /// 現在の全体輝度を読み取る (応答は `currentBrightness` に反映)
    ///
    /// Read 時は board=0x0000 が必要 (mctrl300.py 準拠)。Write のデフォルト 0xFFFF
    /// のままだと実機が ACK エラー (0x05) を返す。
    func readBrightness() {
        let packet = buildPacket(
            isWrite: false,
            register: Register.globalBrightness,
            dest: Packet.destSendingCard,
            boardIndex: 0x0000,
            lengthOverride: 1
        )
        sendRaw(packet)
        print("[USBManager] readBrightness requested")
    }

    /// 現在の RGB 輝度を読み取る (応答は `currentRGB` に反映)
    func readRGBBrightness() {
        let packet = buildPacket(
            isWrite: false,
            register: Register.rgbBrightness,
            dest: Packet.destSendingCard,
            boardIndex: 0x0000,
            lengthOverride: 4
        )
        sendRaw(packet)
        print("[USBManager] readRGBBrightness requested")
    }

    // MARK: - 公開API: ハードウェア情報取得

    /// 実機からハードウェア情報を取得して `connectedDeviceInfo` に反映する
    ///
    /// 接続直後に一度呼ばれる想定。レジスタ参照:
    /// - 0x03100000 (`Sender_NetworkInterfaceCardNumber`, 2B): 受信カード総数
    /// - 0x020001EC (`SenderVideoEnclosingAddr`, 4B): 画面サイズ (W LE16, H LE16)
    /// - 0x00000002 (`ReadControllerModelId`, 2B): コントローラ機種ID
    func readDeviceInfo() async {
        async let cardCountData  = readRegister(0x03100000, length: 2,
                                                dest: Packet.destSendingCard)
        async let screenSizeData = readRegister(0x020001EC, length: 4,
                                                dest: Packet.destSendingCard)
        async let modelIdData    = readRegister(0x00000002, length: 2,
                                                dest: Packet.destSendingCard)

        let (countD, sizeD, modelD) = await (cardCountData, screenSizeData, modelIdData)

        func uint16LE(_ d: Data, offset: Int = 0) -> Int {
            guard d.count >= offset + 2 else { return 0 }
            return Int(d[offset]) | (Int(d[offset + 1]) << 8)
        }

        let cardCount = countD.map { uint16LE($0) } ?? 0
        let width  = sizeD.map { uint16LE($0, offset: 0) } ?? 0
        let height = sizeD.map { uint16LE($0, offset: 2) } ?? 0
        let modelId: UInt16? = modelD.flatMap { d in
            d.count >= 2 ? UInt16(uint16LE(d)) : nil
        }

        let info = DeviceInfo(cardCount: cardCount,
                              screenWidth: width,
                              screenHeight: height,
                              controllerModelId: modelId)
        await MainActor.run {
            self.connectedDeviceInfo = info
        }
        print("[USBManager] DeviceInfo: cards=\(cardCount), screen=\(width)×\(height)px, modelId=\(modelId.map { String(format: "0x%04X", $0) } ?? "nil")")
    }

    // MARK: - 公開API: テストパターン / ディスプレイモード

    /// 内蔵テストパターンを設定する
    ///
    /// `.normal` を送ると Pattern レジスタに 1 を書き込み、パターン表示を解除する。
    /// 結果は `currentPattern` に反映され、`currentDisplayMode` が `.normal` 以外の
    /// 場合は先に解除してからパターンを送る (ブラック/フリーズ中だとパターンが見えないため)。
    func setTestPattern(_ pattern: TestPattern) {
        if currentDisplayMode != .normal {
            setDisplayMode(.normal)
        }
        let packet = buildPacket(
            isWrite: true,
            register: Register.testPattern,
            data: [pattern.rawValue],
            dest: Packet.destSendingCard
        )
        sendRaw(packet)
        DispatchQueue.main.async { self.currentPattern = pattern }
        print("[USBManager] setTestPattern: \(pattern.label)")
    }

    /// ディスプレイモード (通常/フリーズ/ブラック) を設定する
    ///
    /// `.normal` は Blackout(0x02000100) + TestPattern(0x02000101) + Freeze(0x02000102) を
    /// 連続 3 バイトで 0 クリアする (companion-module の Normal パケットと同型)。
    func setDisplayMode(_ mode: DisplayMode) {
        switch mode {
        case .normal:
            // 3 連続レジスタを一括ゼロクリアして全フラグ解除
            let packet = buildPacket(
                isWrite: true,
                register: Register.blackout,
                data: [0x00, 0x00, 0x00]
            )
            sendRaw(packet)
            DispatchQueue.main.async { self.currentPattern = .normal }
        case .freeze:
            let packet = buildPacket(
                isWrite: true,
                register: Register.freeze,
                data: [0xFF]
            )
            sendRaw(packet)
        case .black:
            let packet = buildPacket(
                isWrite: true,
                register: Register.blackout,
                data: [0xFF]
            )
            sendRaw(packet)
        }
        DispatchQueue.main.async { self.currentDisplayMode = mode }
        print("[USBManager] setDisplayMode: \(mode.rawValue)")
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
            // 公式名は sarakusha/novastar の AddressMapping より判明
            self.sendCmd(dest: 0x00, reg: 0x020000F0, data: [0x00])         // VirtualMapAddrNew (1B)
            self.sendCmd(dest: 0x00, reg: 0x02000028, data: [0x00, 0x00])   // DviOffsetXAddr (area1 X)
            self.sendCmd(dest: 0x00, reg: 0x0200002A, data: [0x00, 0x00])   // DviOffsetYAddr (area1 Y)
            self.sendCmd(dest: 0x00, reg: 0x02000024, data: widthLE)        // DviWidthAddr (area1 W)
            self.sendCmd(dest: 0x00, reg: 0x02000026, data: heightLE)       // DviHeightAddr (area1 H)
            self.sendCmd(dest: 0x00, reg: 0x0200002C, data: widthLE)        // RealDviWidthAddr (stride)
            self.sendCmd(dest: 0x00, reg: 0x02000055, data: [0x00, 0x00])   // PortOffsetXAddr (area3)
            self.sendCmd(dest: 0x00, reg: 0x02000057, data: [0x00, 0x00])   // PortOffsetYAddr (area3)
            self.sendCmd(dest: 0x00, reg: 0x02000051, data: widthLE)        // PortWidthAddr (area3)
            self.sendCmd(dest: 0x00, reg: 0x02000053, data: heightLE)       // PortHeightAddr (area3)
            self.sendCmd(dest: 0x00, reg: 0x03100000, data: self.uint16LE(UInt16(totalCards)))  // Sender_NetworkInterfaceCardNumber (cols × rows)
            self.sendCmd(dest: 0x00, reg: 0x02000050, data: [0x00])         // PortEnableAddr

            // === Section 2.5: マッピングテーブル直前の特殊コマンド (キャプチャ line 21) ===
            // reg=0x02020020 は公式名 SenderFunctionAddr (Occupancy=0x40)。
            // NovaLCT が 64 バイト分の領域を先にアロケート/リセットするため必ず送る。
            self.sendCmd(dest: 0x00, port: 0x00, board: 0x0000,
                         reg: 0x02020020, data: [],
                         lengthOverride: 0x0040)

            // === Section 3: マッピングテーブル (16ブロック) ===
            // ベース 0x03000000 = Sender_scannerCoordinateBase (= EthernetPortScannerXAddr)
            // 4B/エントリ [X_LE16][Y_LE16]、1 ポート分 = 4096B = 1024 エントリ
            // 256B×16 ブロックで書き込み
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
            // 0x02000017/19 は送信カード側では別定義 (IsHasDVISignal) だが、
            // 受信カード (deviceType=0x01) 宛てでは ControlWidthAddr / ControlHeightAddr として機能する。
            let order = self.boardOrder(columns: columns, rows: rows,
                                        cabinetWidth: cabinetWidth, cabinetHeight: cabinetHeight,
                                        scanDirection: scanDirection)
            for boardIndex in order {
                let wLE = self.uint16LE(UInt16(cabinetWidth))
                let hLE = self.uint16LE(UInt16(cabinetHeight))
                self.sendCmd(dest: 0x00, port: 0x00, board: UInt16(boardIndex), reg: 0x02000017, data: wLE, deviceType: rcvType)  // ControlWidth
                self.sendCmd(dest: 0x00, port: 0x00, board: UInt16(boardIndex), reg: 0x02000019, data: hLE, deviceType: rcvType)  // ControlHeight
            }

            // === Section 5: コミット (キャプチャ検証済み) ===
            // 0x01000012 = RecaculateParameterAddr — data [0xAA] で設定を確定/再計算させる
            // 0x020001EC = SenderVideoEnclosingAddr — 画面全体サイズを通知
            self.sendCmd(dest: 0xFF, port: 0x00, board: 0x0000, reg: 0x020000AE, data: [0x01])
            self.sendCmd(dest: 0xFF, port: 0xFF, board: 0xFFFF, reg: 0x01000012, data: [0xAA], reserved: 0x08)  // RecaculateParameter
            self.sendCmd(dest: 0x00, reg: 0x020001EC, data: self.uint16LE(UInt16(totalWidth)) + self.uint16LE(UInt16(totalHeight)))  // SenderVideoEnclosing

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

    /// レジスタの値を読み取る (fire-and-forget, 応答はログのみ)
    func readRegister(_ register: UInt32, dest: UInt8 = Packet.destSendingCard, port: UInt8 = Packet.portAll) {
        let packet = buildPacket(isWrite: false, register: register, dest: dest, port: port)
        sendRaw(packet)
    }

    /// レジスタから length バイトの値を非同期で読み取る
    ///
    /// 送信時のシーケンス番号をキーに応答を待機する。timeout 経過で nil を返す。
    func readRegister(_ register: UInt32,
                      length: UInt16,
                      dest: UInt8 = Packet.destReceivingCard,
                      port: UInt8 = Packet.portAll,
                      board: UInt16 = 0,
                      deviceType: UInt8? = nil,
                      timeout: TimeInterval = 1.5) async -> Data? {
        guard serialPort >= 0 else { return nil }
        let seq = nextSerial()
        let packet = buildPacket(isWrite: false, register: register,
                                 dest: dest, port: port,
                                 boardIndex: board,
                                 deviceType: deviceType,
                                 lengthOverride: length,
                                 seq: seq)

        let result = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            pendingLock.lock()
            pendingReads[seq] = cont
            pendingLock.unlock()

            sendRaw(packet)

            // タイムアウト監視
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self else { return }
                self.pendingLock.lock()
                let waiting = self.pendingReads.removeValue(forKey: seq)
                self.pendingLock.unlock()
                waiting?.resume(returning: nil)
            }
        }
        return result
    }

    // MARK: - 公開API: 受信カードヘルス取得
    //
    // Portions adapted from @novastar/screen (sarakusha/novastar)
    // Copyright (c) 2019 Andrei Sarakeev — MIT License

    /// 受信カード監視データの読み取り先レジスタ (Scanner_AllMonitorDataAddr)
    private static let cardHealthRegister: UInt32 = 0x0A000000
    /// 監視データの総バイト数 (Scanner_AllMonitorDataOccupancy)
    private static let cardHealthLength: UInt16 = 82

    /// 指定ボードの受信カードから健康状態を読み取る
    ///
    /// - Parameters:
    ///   - boardIndex: 受信カードのインデックス (0..<cardCount)
    ///   - port: ポートアドレス (既定 0x00 = port 0。MSD300 は単一ポート想定)
    ///
    /// 既定は port=0x00。NovaLCT のキャプチャと sarakusha/novastar の実装は
    /// 「特定ポート」を指定して受信カードへ問い合わせる形を取っているため。
    func readCardHealth(boardIndex: UInt16, port: UInt8 = 0x00) async -> CardHealth? {
        let data = await readRegister(Self.cardHealthRegister,
                                      length: Self.cardHealthLength,
                                      dest: Packet.destReceivingCard,
                                      port: port,
                                      board: boardIndex,
                                      deviceType: Packet.deviceTypeReceivingCard)
        guard let data = data else {
            print("[USBManager] readCardHealth(board=\(boardIndex)) timeout / no response")
            return nil
        }
        if data.isEmpty {
            print("[USBManager] readCardHealth(board=\(boardIndex)) empty payload")
            return nil
        }
        print("[USBManager] readCardHealth(board=\(boardIndex)) got \(data.count) bytes")
        return CardHealth.parse(data)
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
                    self.lastError = "Send error: \(err)"
                }
            } else {
                print("[USBManager] Sent \(written) bytes: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
        }
    }
}

// MARK: - CardHealth
//
// 受信カードの健康状態 (温度 / 湿度 / 電圧 / ファン / モジュールエラー)。
// Scanner_AllMonitorDataAddr (0x0A000000) から 82 バイトの応答をパースする。
//
// Portions adapted from @novastar/screen HWStatus.ts (sarakusha/novastar)
// Copyright (c) 2019 Andrei Sarakeev — MIT License

struct CardHealth {
    struct TempReading {
        let isValid: Bool
        let celsius: Double
    }
    struct ValueReading {
        let isValid: Bool
        let value: Int
    }
    struct VoltageReading {
        let isValid: Bool
        let volts: Double
    }
    struct FanReading {
        let isValid: Bool
        let rpm: Int
    }

    let scanCardTemp: TempReading           // offset 0 (2B)
    let scanCardHumidity: ValueReading      // offset 2 (1B)
    let scanCardVoltage: VoltageReading     // offset 3 (1B)
    let moduleStatusLow: Data               // offset 11 (16B)
    let isMonitorCardConnected: Bool        // offset 32 (1B)
    let monitorCardTemp: TempReading        // offset 39 (2B)
    let monitorCardHumidity: ValueReading   // offset 41 (1B)
    let monitorCardSmoke: ValueReading      // offset 42 (1B)
    let monitorCardFans: [FanReading]       // offset 43 (4B)
    let monitorCardVoltages: [VoltageReading] // offset 47 (9B)
    let analogInput: Data                   // offset 56 (8B)
    let generalStatus: UInt8                // offset 65
    let moduleStatusHigh: Data              // offset 66 (16B)

    /// 異常モジュールのフラグが 1 つでも立っていれば true
    var hasModuleError: Bool {
        return moduleStatusLow.contains(where: { $0 != 0 })
            || moduleStatusHigh.contains(where: { $0 != 0 })
    }

    /// 82 バイトの応答 payload を CardHealth にパースする
    static func parse(_ data: Data) -> CardHealth? {
        guard data.count >= 82 else { return nil }
        let b = [UInt8](data)

        // ビット解釈は sarakusha/novastar HWStatus.ts の struct 定義を忠実に移植。
        // 温度: byte[0] bit0=IsValid, (byte[0] & 0x7f)==1 のとき負符号、byte[1] が value×0.5℃
        func tempInfo(_ o: Int) -> TempReading {
            let flags = b[o]
            let value = b[o + 1]
            let isValid = (flags & 0x01) == 1
            let sign: Double = ((flags & 0x7f) == 1) ? -0.5 : 0.5
            return TempReading(isValid: isValid, celsius: sign * Double(value))
        }
        // 1バイト: bit0=IsValid, bit1-7=Value
        func valueInfo(_ o: Int) -> ValueReading {
            let byte = b[o]
            return ValueReading(isValid: (byte & 0x01) == 1,
                                value: Int((byte >> 1) & 0x7f))
        }
        // 1バイト: bit0=IsValid, value = (byte & 0x7f) / 10 [V]
        func voltageInfo(_ o: Int) -> VoltageReading {
            let byte = b[o]
            return VoltageReading(isValid: (byte & 0x01) == 1,
                                  volts: Double(byte & 0x7f) / 10.0)
        }
        // 1バイト: bit0=IsValid, value = (byte & 0x7f) * 50 [RPM]
        func fanInfo(_ o: Int) -> FanReading {
            let byte = b[o]
            return FanReading(isValid: (byte & 0x01) == 1,
                              rpm: Int(byte & 0x7f) * 50)
        }

        let fans = (0..<4).map { fanInfo(43 + $0) }
        let voltages = (0..<9).map { voltageInfo(47 + $0) }

        return CardHealth(
            scanCardTemp: tempInfo(0),
            scanCardHumidity: valueInfo(2),
            scanCardVoltage: voltageInfo(3),
            moduleStatusLow: Data(b[11..<27]),
            isMonitorCardConnected: b[32] != 0,
            monitorCardTemp: tempInfo(39),
            monitorCardHumidity: valueInfo(41),
            monitorCardSmoke: valueInfo(42),
            monitorCardFans: fans,
            monitorCardVoltages: voltages,
            analogInput: Data(b[56..<64]),
            generalStatus: b[65],
            moduleStatusHigh: Data(b[66..<82])
        )
    }
}
