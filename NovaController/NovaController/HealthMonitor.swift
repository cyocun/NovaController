import Foundation
import Observation
import UserNotifications

// MARK: - HealthSample

/// 受信カード 1 枚 1 時点のスナップショット
struct HealthSample {
    let timestamp: Date
    let temperature: Double?  // ℃ (invalid 時 nil)
    let voltage: Double?      // V  (invalid 時 nil)
    let hasModuleError: Bool
}

// MARK: - CardHistory

/// 単一カードの 24h 時系列。末尾追加 + 24h を超えた古いサンプルを自動ドロップ。
struct CardHistory {
    static let retention: TimeInterval = 24 * 60 * 60

    private(set) var samples: [HealthSample] = []

    mutating func append(_ sample: HealthSample) {
        samples.append(sample)
        let cutoff = sample.timestamp.addingTimeInterval(-Self.retention)
        if let first = samples.first, first.timestamp < cutoff {
            samples.removeAll { $0.timestamp < cutoff }
        }
    }

    /// 有効サンプルの温度値列 (スパークライン描画用)
    var temperatures: [Double] { samples.compactMap { $0.temperature } }
    /// 有効サンプルの電圧値列
    var voltages: [Double] { samples.compactMap { $0.voltage } }
}

// MARK: - HealthThresholds

/// 警告閾値。UserDefaults に JSON で永続化。
struct HealthThresholds: Codable, Equatable {
    var tempMax: Double = 60.0
    var voltageMin: Double = 4.0
    var voltageMax: Double = 6.0
    var alertOnModuleError: Bool = true

    private static let storageKey = "HealthThresholds.v1"

    static func load() -> HealthThresholds {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(HealthThresholds.self, from: data) else {
            return HealthThresholds()
        }
        return value
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

// MARK: - HealthMonitor

/// 受信カードの健康状態を履歴化し、閾値超過で macOS 通知を発火する中枢。
///
/// HealthView から `record(board:health:)` を呼ぶと履歴に追記し、閾値評価と通知送信まで自動で行う。
/// 同じ異常が継続している間は再通知せず、一度解消してから再発したときに再通知する。
@Observable
final class HealthMonitor {
    static let shared = HealthMonitor()

    /// UI に表示する現在の閾値設定
    var thresholds: HealthThresholds

    /// カード (board index) → 履歴
    @ObservationIgnored private var histories: [Int: CardHistory] = [:]
    /// カード → 直近で通知済みのアラート種別セット (連続通知防止)
    @ObservationIgnored private var lastAlerted: [Int: Set<AlertType>] = [:]
    /// 通知権限取得済みフラグ
    @ObservationIgnored private var didRequestAuthorization = false

    enum AlertType: String {
        case tempHigh
        case voltageOutOfRange
        case moduleError
    }

    private init() {
        self.thresholds = HealthThresholds.load()
    }

    // MARK: - 公開API

    /// カードの履歴を取得 (読み取り専用)
    func history(for board: Int) -> CardHistory {
        histories[board] ?? CardHistory()
    }

    /// CardHealth を取り込んで履歴追記 + 閾値評価
    func record(board: Int, health: CardHealth, at time: Date = Date()) {
        ensureAuthorization()

        let sample = HealthSample(
            timestamp: time,
            temperature: health.scanCardTemp.isValid ? health.scanCardTemp.celsius : nil,
            voltage: health.scanCardVoltage.isValid ? health.scanCardVoltage.volts : nil,
            hasModuleError: health.hasModuleError
        )

        var history = histories[board] ?? CardHistory()
        history.append(sample)
        histories[board] = history

        evaluate(board: board, sample: sample)
    }

    /// 閾値をユーザー設定から更新
    func updateThresholds(_ new: HealthThresholds) {
        thresholds = new
        new.save()
    }

    // MARK: - 閾値評価

    private func evaluate(board: Int, sample: HealthSample) {
        var active = Set<AlertType>()

        if let t = sample.temperature, t > thresholds.tempMax {
            active.insert(.tempHigh)
        }
        if let v = sample.voltage,
           v < thresholds.voltageMin || v > thresholds.voltageMax {
            active.insert(.voltageOutOfRange)
        }
        if thresholds.alertOnModuleError && sample.hasModuleError {
            active.insert(.moduleError)
        }

        let previous = lastAlerted[board] ?? []
        let newlyTriggered = active.subtracting(previous)
        for alert in newlyTriggered {
            sendNotification(board: board, alert: alert, sample: sample)
        }
        lastAlerted[board] = active
    }

    // MARK: - 通知

    private func ensureAuthorization() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(board: Int, alert: AlertType, sample: HealthSample) {
        let content = UNMutableNotificationContent()
        content.title = "受信カード #\(board + 1) 警告"
        content.body = messageBody(for: alert, sample: sample)
        content.sound = .default

        // identifier をカード×アラート種別で一意にし、再通知時は同IDで上書き
        let req = UNNotificationRequest(
            identifier: "health.\(board).\(alert.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func messageBody(for alert: AlertType, sample: HealthSample) -> String {
        switch alert {
        case .tempHigh:
            let t = sample.temperature ?? 0
            return String(format: "温度が閾値を超えました (%.1f℃ / 上限 %.1f℃)",
                          t, thresholds.tempMax)
        case .voltageOutOfRange:
            let v = sample.voltage ?? 0
            return String(format: "電圧が範囲外です (%.2fV / 範囲 %.1f〜%.1fV)",
                          v, thresholds.voltageMin, thresholds.voltageMax)
        case .moduleError:
            return "モジュールエラーを検出しました"
        }
    }
}
