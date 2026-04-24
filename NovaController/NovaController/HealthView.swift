import SwiftUI

// MARK: - HealthView

struct HealthView: View {
    @State private var cards: [Int: CardHealth] = [:]
    @State private var isPolling: Bool = false
    @State private var lastUpdate: Date? = nil
    @State private var pollTask: Task<Void, Never>? = nil
    private let usbManager = USBManager.shared
    private let monitor = HealthMonitor.shared

    /// 実機から取得した受信カード数。未取得時は 0
    private var cardCount: Int { usbManager.connectedDeviceInfo?.cardCount ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            // 左メインエリア: カード一覧
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("監視")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Color(hex: "#2d3436"))
                    Spacer()
                    if let last = lastUpdate {
                        Text("最終更新: \(timeFormatter.string(from: last))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                if !usbManager.isConnected {
                    NoticeBox(symbol: "bolt.slash", message: "MSD300 が未接続のため監視できません")
                } else if cardCount == 0 {
                    NoticeBox(symbol: "questionmark.circle", message: "実機からカード構成を取得中…")
                } else if cards.isEmpty && !isPolling {
                    NoticeBox(symbol: "waveform", message: "「監視を開始」で受信カードの状態を取得します")
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(0..<cardCount, id: \.self) { idx in
                                CardHealthRow(
                                    index: idx,
                                    health: cards[idx],
                                    temperatureHistory: monitor.history(for: idx).temperatures,
                                    tempMax: monitor.thresholds.tempMax
                                )
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                Button(action: togglePolling) {
                    Text(pollButtonLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(pollButtonColor)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(!usbManager.isConnected)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // 右サイド: 実機情報 + 閾値
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSection(title: "実機情報") {
                        StatusRow(label: "カード数",
                                  value: cardCount > 0 ? "\(cardCount)" : "—")
                        StatusRow(label: "画面サイズ", value: screenSizeString)
                        StatusRow(label: "機種ID", value: modelIdString)
                    }

                    SettingsSection(title: "状態") {
                        StatusRow(label: "取得済み", value: "\(cards.count)")
                        StatusRow(label: "更新間隔", value: "5 秒")
                        StatusRow(label: "履歴保持", value: "24 時間")
                    }

                    SettingsSection(title: "警告閾値") {
                        ThresholdStepper(
                            label: "温度上限",
                            value: monitor.thresholds.tempMax,
                            range: 40...80,
                            step: 1,
                            unit: "℃"
                        ) { newValue in
                            var t = monitor.thresholds
                            t.tempMax = newValue
                            monitor.updateThresholds(t)
                        }
                        ThresholdStepper(
                            label: "電圧下限",
                            value: monitor.thresholds.voltageMin,
                            range: 3.0...5.5,
                            step: 0.1,
                            unit: "V"
                        ) { newValue in
                            var t = monitor.thresholds
                            t.voltageMin = newValue
                            monitor.updateThresholds(t)
                        }
                        ThresholdStepper(
                            label: "電圧上限",
                            value: monitor.thresholds.voltageMax,
                            range: 5.0...7.0,
                            step: 0.1,
                            unit: "V"
                        ) { newValue in
                            var t = monitor.thresholds
                            t.voltageMax = newValue
                            monitor.updateThresholds(t)
                        }
                        Toggle(isOn: Binding(
                            get: { monitor.thresholds.alertOnModuleError },
                            set: { newValue in
                                var t = monitor.thresholds
                                t.alertOnModuleError = newValue
                                monitor.updateThresholds(t)
                            }
                        )) {
                            Text("モジュールエラー通知")
                                .font(.system(size: 11))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .frame(width: 240)
            .background(Color.white)
        }
        .onDisappear {
            stopPolling()
        }
    }

    // MARK: - ポーリング

    private func togglePolling() {
        if isPolling { stopPolling() } else { startPolling() }
    }

    private func startPolling() {
        isPolling = true
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5s
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    private func refresh() async {
        var snapshot: [Int: CardHealth] = [:]
        for idx in 0..<cardCount {
            if let h = await usbManager.readCardHealth(boardIndex: UInt16(idx)) {
                snapshot[idx] = h
            }
        }
        let now = Date()
        await MainActor.run {
            self.cards = snapshot
            self.lastUpdate = now
            // 24h 履歴に追記 + 閾値評価 + 超過時は通知
            for (idx, health) in snapshot {
                monitor.record(board: idx, health: health, at: now)
            }
        }
    }

    private var pollButtonLabel: String {
        if !usbManager.isConnected { return "未接続" }
        return isPolling ? "監視を停止" : "監視を開始"
    }

    private var pollButtonColor: Color {
        if !usbManager.isConnected { return Color(hex: "#b2bec3") }
        return isPolling ? Color(hex: "#e94560") : Color(hex: "#0f3460")
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }

    private var screenSizeString: String {
        guard let info = usbManager.connectedDeviceInfo,
              info.screenWidth > 0, info.screenHeight > 0 else { return "—" }
        return "\(info.screenWidth) × \(info.screenHeight) px"
    }

    private var modelIdString: String {
        guard let id = usbManager.connectedDeviceInfo?.controllerModelId else { return "—" }
        return String(format: "0x%04X", id)
    }
}

// MARK: - CardHealthRow

struct CardHealthRow: View {
    let index: Int
    let health: CardHealth?
    let temperatureHistory: [Double]
    let tempMax: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("カード #\(index + 1)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "#2d3436"))
                Spacer()
                statusBadge
            }

            if let h = health {
                HStack(spacing: 16) {
                    MetricView(icon: "thermometer", label: "温度",
                               value: temperatureString(h.scanCardTemp))
                    MetricView(icon: "humidity", label: "湿度",
                               value: h.scanCardHumidity.isValid ? "\(h.scanCardHumidity.value)%" : "—")
                    MetricView(icon: "bolt", label: "電圧",
                               value: voltageString(h.scanCardVoltage))
                    Spacer()
                    Sparkline(values: temperatureHistory, threshold: tempMax)
                        .frame(width: 110, height: 26)
                }

                if h.isMonitorCardConnected {
                    HStack(spacing: 16) {
                        MetricView(icon: "fanblades", label: "ファン",
                                   value: fanString(h.monitorCardFans))
                        MetricView(icon: "smoke", label: "煙",
                                   value: h.monitorCardSmoke.isValid
                                       ? (h.monitorCardSmoke.value > 0 ? "警告" : "正常")
                                       : "—")
                    }
                }
            } else {
                Text("データ取得中 / 未受信")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "#e8ecf0"), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let h = health {
            if h.hasModuleError {
                StatusBadge(text: "エラー", color: Color(hex: "#e94560"))
            } else {
                StatusBadge(text: "正常", color: Color(hex: "#27ae60"))
            }
        } else {
            StatusBadge(text: "—", color: Color(hex: "#b2bec3"))
        }
    }

    private func temperatureString(_ t: CardHealth.TempReading) -> String {
        guard t.isValid else { return "—" }
        return String(format: "%.1f℃", t.celsius)
    }

    private func voltageString(_ v: CardHealth.VoltageReading) -> String {
        guard v.isValid else { return "—" }
        return String(format: "%.1fV", v.volts)
    }

    private func fanString(_ fans: [CardHealth.FanReading]) -> String {
        let valid = fans.filter { $0.isValid }
        guard !valid.isEmpty else { return "—" }
        let avg = valid.map { $0.rpm }.reduce(0, +) / valid.count
        return "\(avg) RPM"
    }
}

// MARK: - MetricView

struct MetricView: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(hex: "#2d3436"))
            }
        }
    }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(
                Capsule().stroke(color.opacity(0.6), lineWidth: 1)
            )
    }
}

// MARK: - NoticeBox

struct NoticeBox: View {
    let symbol: String
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "#e8ecf0"), lineWidth: 1)
        )
    }
}

// MARK: - Sparkline

/// 数値の時系列を細い折れ線でミニ表示する。閾値を超えた領域は赤味で塗り分け。
struct Sparkline: View {
    let values: [Double]
    let threshold: Double

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else {
                // データ不足時は控えめなプレースホルダ線
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(path, with: .color(Color(hex: "#dfe4ea")), lineWidth: 1)
                return
            }

            let minV = (values.min() ?? 0) - 2
            let maxV = max((values.max() ?? 0) + 2, threshold + 2)
            let range = max(maxV - minV, 1)

            // 閾値ライン
            let thresholdY = size.height - CGFloat((threshold - minV) / range) * size.height
            var thresholdPath = Path()
            thresholdPath.move(to: CGPoint(x: 0, y: thresholdY))
            thresholdPath.addLine(to: CGPoint(x: size.width, y: thresholdY))
            ctx.stroke(thresholdPath,
                       with: .color(Color(hex: "#e94560").opacity(0.4)),
                       style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))

            // 折れ線
            var path = Path()
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) / CGFloat(values.count - 1) * size.width
                let y = size.height - CGFloat((v - minV) / range) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else      { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            let lineColor: Color = (values.last ?? 0) > threshold
                ? Color(hex: "#e94560")
                : Color(hex: "#0f3460")
            ctx.stroke(path, with: .color(lineColor), lineWidth: 1.4)
        }
    }
}

// MARK: - ThresholdStepper

/// 閾値設定用の Stepper 行。値変更を即座に onChange へ通知。
struct ThresholdStepper: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let onChange: (Double) -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Stepper(
                value: Binding(
                    get: { value },
                    set: { onChange($0) }
                ),
                in: range,
                step: step
            ) {
                Text(formatted)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .controlSize(.mini)
        }
    }

    private var formatted: String {
        // step が整数なら小数なし、そうでなければ小数 1 桁
        if step >= 1 {
            return "\(Int(value))\(unit)"
        }
        return String(format: "%.1f%@", value, unit)
    }
}

#Preview {
    HealthView()
}
