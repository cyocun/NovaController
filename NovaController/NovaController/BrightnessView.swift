import SwiftUI

// MARK: - BrightnessSchedule

struct BrightnessSchedule: Identifiable {
    let id = UUID()
    var time: String
    var brightness: Double
}

// MARK: - BrightnessView

struct BrightnessView: View {
    @State private var brightness: Double = 80
    @State private var scheduleEnabled: Bool = false
    @State private var schedules: [BrightnessSchedule] = [
        BrightnessSchedule(time: "08:00", brightness: 80),
        BrightnessSchedule(time: "22:00", brightness: 30),
    ]
    @State private var lastApplied: Double? = nil

    // RGB ホワイトバランス (0-255)。neutral = 0xF0 (=240)
    @State private var red: Double = 240
    @State private var green: Double = 240
    @State private var blue: Double = 240

    /// 適用対象パネル。nil=全パネル、値=特定ボード index
    @State private var targetBoard: UInt16? = nil

    private let usbManager = USBManager.shared

    /// 実機から取得した受信カード数 (未取得時は 0)
    private var boardCount: Int { usbManager.connectedDeviceInfo?.cardCount ?? 0 }

    var isApplied: Bool { lastApplied == brightness }
    private var brightnessInt: Int { Int(brightness.rounded()) }

    var body: some View {
        HStack(spacing: 0) {
            // 左メインエリア
            VStack(alignment: .leading, spacing: 24) {
                Text("Brightness")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Color(hex: "#2d3436"))

                // メーター + 微調整 (フラット)
                VStack(spacing: 32) {
                    HStack(spacing: 28) {
                        AdjustButton(symbol: "minus") {
                            brightness = max(0, brightness - 1)
                        }

                        BrightnessGaugeView(brightness: $brightness)
                            .frame(width: 240, height: 240)

                        AdjustButton(symbol: "plus") {
                            brightness = min(100, brightness + 1)
                        }
                    }

                    // プリセット (フラット)
                    HStack(spacing: 6) {
                        ForEach([0, 25, 50, 75, 100], id: \.self) { preset in
                            Button(action: { brightness = Double(preset) }) {
                                Text("\(preset)%")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(PresetButtonStyle(isSelected: brightnessInt == preset))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)

                // 適用ボタン
                Button(action: applyBrightness) {
                    Text(applyButtonLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(applyButtonColor)
                        .cornerRadius(8)
                        .animation(.easeInOut(duration: 0.2), value: isApplied)
                }
                .buttonStyle(.plain)
                .disabled(!usbManager.isConnected)

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // 右設定パネル (フラット)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSection(title: "Target") {
                        Menu {
                            Button("All Panels") { targetBoard = nil }
                            if boardCount > 0 {
                                Divider()
                                ForEach(0..<boardCount, id: \.self) { idx in
                                    Button("Board #\(idx)") { targetBoard = UInt16(idx) }
                                }
                            }
                        } label: {
                            HStack {
                                Text(targetLabel)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Color(hex: "#2d3436"))
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color(hex: "#f5f6fa"))
                            .cornerRadius(6)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        if boardCount == 0 {
                            Text("Fetching card count…")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    SettingsSection(title: "RGB White Balance") {
                        RGBSlider(label: "R", value: $red, tint: Color(hex: "#e74c3c"))
                        RGBSlider(label: "G", value: $green, tint: Color(hex: "#2ecc71"))
                        RGBSlider(label: "B", value: $blue, tint: Color(hex: "#3498db"))

                        Button(action: resetRGB) {
                            Text("Reset to neutral (240,240,240)")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(SmallButtonStyle(color: Color(hex: "#95a5a6")))
                    }

                    SettingsSection(title: "Schedule") {
                        Toggle("Enable schedule", isOn: $scheduleEnabled)
                            .font(.system(size: 12))
                            .toggleStyle(.switch)
                            .controlSize(.mini)

                        if scheduleEnabled {
                            ForEach($schedules) { $schedule in
                                ScheduleRow(schedule: $schedule)
                            }

                            Button(action: {
                                schedules.append(BrightnessSchedule(time: "12:00", brightness: 50))
                            }) {
                                Label("Add", systemImage: "plus.circle")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(SmallButtonStyle(color: Color(hex: "#0f3460")))
                        }
                    }

                    SettingsSection(title: "Status") {
                        StatusRow(label: "UI value", value: "\(brightnessInt)%")
                        StatusRow(label: "Device value",
                                  value: usbManager.currentBrightness.map { "\($0)%" } ?? "—")
                        StatusRow(label: "Applied", value: isApplied ? "Yes" : "No")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .frame(width: 240)
            .background(Color.white)
        }
    }

    private var targetLabel: String {
        if let board = targetBoard { return "Board #\(board)" }
        return "All Panels"
    }

    private func resetRGB() {
        red = 240; green = 240; blue = 240
    }

    private func applyBrightness() {
        lastApplied = brightness
        USBManager.shared.setBrightness(
            brightnessInt,
            r: UInt8(red.rounded()),
            g: UInt8(green.rounded()),
            b: UInt8(blue.rounded()),
            board: targetBoard
        )
    }

    private var applyButtonLabel: String {
        if !usbManager.isConnected { return "Disconnected" }
        return isApplied ? "Applied" : "Apply Brightness"
    }

    private var applyButtonColor: Color {
        if !usbManager.isConnected { return Color(hex: "#b2bec3") }
        return isApplied ? Color(hex: "#27ae60") : Color(hex: "#0f3460")
    }
}

// MARK: - BrightnessGaugeView
//
// 270°ゲージ。0%=左上(225°), 時計回りに100%=右上(135°=225+270)。
// 下半分が繋がった「上が開いた U 字」の形状。ドラッグで値を変更可能。

struct BrightnessGaugeView: View {
    @Binding var brightness: Double

    private static let gaugeStart: Double = 135.0   // 開始角度 (deg, 0%位置=左下)
    private static let gaugeSweep: Double = 270.0   // ゲージの総角度

    /// 輝度グラデ: 0%=暗 → 100%=明 の明度変化 (モノトーン)
    private static let gaugeGradient = Gradient(stops: [
        .init(color: Color(hex: "#16213e"), location: 0.0),
        .init(color: Color(hex: "#e5eaf2"), location: 1.0),
    ])

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 背景の円弧
                GaugeArc(progress: 1.0)
                    .stroke(
                        Color(hex: "#edf2f7"),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round)
                    )

                // 値の円弧
                GaugeArc(progress: brightness / 100)
                    .stroke(
                        AngularGradient(
                            gradient: Self.gaugeGradient,
                            center: .center,
                            startAngle: .degrees(Self.gaugeStart),
                            endAngle: .degrees(Self.gaugeStart + Self.gaugeSweep)
                        ),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round)
                    )
                    .animation(.easeOut(duration: 0.15), value: brightness)

                // 中心テキスト
                VStack(spacing: 0) {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text("\(Int(brightness.rounded()))")
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "#2d3436"))
                            .monospacedDigit()
                        Text("%")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                    Text("Drag to adjust")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                        .tracking(1)
                        .padding(.top, 2)
                }
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if let newValue = Self.brightness(from: value.location, in: geo.size) {
                            brightness = newValue
                        }
                    }
            )
        }
    }

    /// マウス位置からゲージ上の輝度 (0-100) を逆算する
    private static func brightness(from point: CGPoint, in size: CGSize) -> Double? {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        // atan2: -π〜π (0=3時, +=時計回り in y-down)
        let angleRad = atan2(dy, dx)
        var angle = angleRad * 180 / .pi
        if angle < 0 { angle += 360 }   // 0-360 に正規化

        // gaugeStart(225°) から時計回りに 0-270° が有効範囲
        var sweep = angle - gaugeStart
        if sweep < 0 { sweep += 360 }

        if sweep <= gaugeSweep {
            return sweep / gaugeSweep * 100
        }
        // 穴の領域 (45°〜225° 反時計回り側): 中点で二分してクランプ
        // sweep は 270〜360 の範囲
        return sweep < (gaugeSweep + (360 - gaugeSweep) / 2) ? 100 : 0
    }
}

// MARK: - GaugeArc

/// ゲージ用の弧パス。
/// progress=0.0 で点のみ、1.0 で全 270° の弧を描画する。
struct GaugeArc: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        let lineWidthHalf: CGFloat = 9
        let radius = min(rect.width, rect.height) / 2 - lineWidthHalf
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = Angle.degrees(135)
        let end = Angle.degrees(135 + 270 * max(0, min(1, progress)))
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: start, endAngle: end,
                    clockwise: false)  // 画面上・時計回り
        return path
    }
}

// MARK: - AdjustButton

struct AdjustButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#0f3460"))
                .frame(width: 32, height: 32)
                .overlay(
                    Circle()
                        .stroke(Color(hex: "#d6dbe3"), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - RGBSlider

struct RGBSlider: View {
    let label: String
    @Binding var value: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(tint)
                    .frame(width: 14, alignment: .leading)
                Slider(value: $value, in: 0...255)
                    .tint(tint)
                    .controlSize(.mini)
                Text("\(Int(value.rounded()))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 28, alignment: .trailing)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - ScheduleRow

struct ScheduleRow: View {
    @Binding var schedule: BrightnessSchedule

    var body: some View {
        HStack(spacing: 8) {
            TextField("HH:MM", text: $schedule.time)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 50)
                .textFieldStyle(.roundedBorder)

            Stepper(value: $schedule.brightness, in: 0...100, step: 5) {
                Text("\(Int(schedule.brightness))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minWidth: 36, alignment: .trailing)
            }
            .controlSize(.mini)
        }
    }
}

// MARK: - StatusRow

struct StatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
    }
}

// MARK: - PresetButtonStyle

struct PresetButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isSelected ? Color(hex: "#0f3460") : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .stroke(isSelected ? Color(hex: "#0f3460") : Color.clear, lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

#Preview {
    BrightnessView()
}
