import SwiftUI

// MARK: - HealthView

struct HealthView: View {
    @State private var cards: [Int: CardHealth] = [:]
    @State private var isPolling: Bool = false
    @State private var lastUpdate: Date? = nil
    @State private var pollTask: Task<Void, Never>? = nil
    @State private var selectedPreset: USBManager.LayoutPreset = .fourByOneLTR
    private let usbManager = USBManager.shared

    private var cardCount: Int { selectedPreset.columns * selectedPreset.rows }

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
                } else if cards.isEmpty && !isPolling {
                    NoticeBox(symbol: "waveform", message: "「監視を開始」で受信カードの状態を取得します")
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(0..<cardCount, id: \.self) { idx in
                                CardHealthRow(index: idx, health: cards[idx])
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

            // 右サイド: プリセット選択 + 状態
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSection(title: "対象プリセット") {
                        ForEach(USBManager.LayoutPreset.allCases) { preset in
                            Button(action: { selectedPreset = preset; cards = [:] }) {
                                HStack {
                                    Text(preset.rawValue)
                                        .font(.system(size: 12,
                                                      weight: selectedPreset == preset ? .semibold : .regular))
                                        .foregroundColor(selectedPreset == preset ? Color(hex: "#2d3436") : .secondary)
                                    Spacer()
                                    if selectedPreset == preset {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(Color(hex: "#0f3460"))
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    SettingsSection(title: "状態") {
                        StatusRow(label: "カード数", value: "\(cardCount)")
                        StatusRow(label: "取得済み", value: "\(cards.count)")
                        StatusRow(label: "更新間隔", value: "5 秒")
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
        await MainActor.run {
            self.cards = snapshot
            self.lastUpdate = Date()
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
}

// MARK: - CardHealthRow

struct CardHealthRow: View {
    let index: Int
    let health: CardHealth?

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

#Preview {
    HealthView()
}
