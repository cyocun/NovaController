import SwiftUI

// MARK: - TestPatternView

struct TestPatternView: View {
    private let usbManager = USBManager.shared

    private var selectedPattern: USBManager.TestPattern { usbManager.currentPattern }
    private var selectedMode: USBManager.DisplayMode { usbManager.currentDisplayMode }

    var body: some View {
        HStack(spacing: 0) {
            // 左メインエリア
            VStack(alignment: .leading, spacing: 24) {
                Text("Test Pattern")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Color(hex: "#2d3436"))

                // ディスプレイモード (通常 / フリーズ / ブラック)
                SectionLabel(title: "Display Mode")
                HStack(spacing: 8) {
                    ForEach(USBManager.DisplayMode.allCases) { mode in
                        DisplayModeButton(
                            mode: mode,
                            isSelected: selectedMode == mode,
                            isEnabled: usbManager.isConnected
                        ) {
                            usbManager.setDisplayMode(mode)
                        }
                    }
                }

                // パターン (9種)
                SectionLabel(title: "Pattern")
                LazyVGrid(columns: [GridItem](repeating: .init(.flexible(), spacing: 10), count: 3),
                          spacing: 10) {
                    ForEach(USBManager.TestPattern.allCases) { pattern in
                        PatternCard(
                            pattern: pattern,
                            isSelected: selectedPattern == pattern,
                            isEnabled: usbManager.isConnected
                        ) {
                            usbManager.setTestPattern(pattern)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // 右設定パネル
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSection(title: "Current") {
                        StatusRow(label: "Mode", value: selectedMode.rawValue)
                        StatusRow(label: "Pattern", value: selectedPattern.label)
                    }
                    SettingsSection(title: "Shortcuts") {
                        ShortcutRow(keys: "⌘0", label: "Off")
                        ShortcutRow(keys: "⌘1–8", label: "Patterns")
                        ShortcutRow(keys: "⌘⇧F", label: "Freeze")
                        ShortcutRow(keys: "⌘⇧B", label: "Black")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .frame(width: 240)
            .background(Color.white)
        }
    }
}

// MARK: - ShortcutRow

private struct ShortcutRow: View {
    let keys: String
    let label: String

    var body: some View {
        HStack {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "#0f3460"))
                .frame(width: 56, alignment: .leading)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

// MARK: - SectionLabel

private struct SectionLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary.opacity(0.8))
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

// MARK: - DisplayModeButton

private struct DisplayModeButton: View {
    let mode: USBManager.DisplayMode
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                Text(mode.rawValue)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : Color(hex: "#2d3436"))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color(hex: "#0f3460") : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.clear : Color(hex: "#e8ecf0"), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.55)
    }

    private var iconName: String {
        switch mode {
        case .normal: return "play.fill"
        case .freeze: return "pause.fill"
        case .black:  return "moon.fill"
        }
    }
}

// MARK: - PatternCard

private struct PatternCard: View {
    let pattern: USBManager.TestPattern
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                PatternPreview(pattern: pattern)
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(hex: "#d6dbe3"), lineWidth: 0.5)
                    )
                Text(pattern.label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Color(hex: "#0f3460") : Color(hex: "#2d3436"))
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color(hex: "#eaf1f9") : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color(hex: "#0f3460") : Color(hex: "#e8ecf0"),
                            lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.55)
    }
}

// MARK: - PatternPreview

/// 各テストパターンの視覚プレビュー。実機の出力を想起させる描画。
private struct PatternPreview: View {
    let pattern: USBManager.TestPattern

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch pattern {
                case .normal:
                    Rectangle().fill(Color(hex: "#f5f6fa"))
                    Image(systemName: "tv")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary.opacity(0.7))
                case .red:
                    Rectangle().fill(Color(hex: "#e74c3c"))
                case .green:
                    Rectangle().fill(Color(hex: "#2ecc71"))
                case .blue:
                    Rectangle().fill(Color(hex: "#3498db"))
                case .white:
                    Rectangle().fill(Color.white)
                case .horizontal:
                    StripePreview(orientation: .horizontal, size: geo.size)
                case .vertical:
                    StripePreview(orientation: .vertical, size: geo.size)
                case .diagonal:
                    DiagonalPreview(size: geo.size)
                case .grayscale:
                    LinearGradient(colors: [.black, .white],
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
        }
    }
}

// MARK: - StripePreview

private struct StripePreview: View {
    enum Orientation { case horizontal, vertical }
    let orientation: Orientation
    let size: CGSize

    var body: some View {
        Canvas { ctx, s in
            ctx.fill(Path(CGRect(origin: .zero, size: s)), with: .color(.black))
            let stripeWidth: CGFloat = 8
            var x: CGFloat = 0
            var toggle = true
            while x < max(s.width, s.height) {
                let rect: CGRect
                switch orientation {
                case .horizontal:
                    rect = CGRect(x: 0, y: x, width: s.width, height: stripeWidth)
                case .vertical:
                    rect = CGRect(x: x, y: 0, width: stripeWidth, height: s.height)
                }
                if toggle {
                    ctx.fill(Path(rect), with: .color(.white))
                }
                x += stripeWidth
                toggle.toggle()
            }
        }
    }
}

// MARK: - DiagonalPreview

private struct DiagonalPreview: View {
    let size: CGSize

    var body: some View {
        Canvas { ctx, s in
            ctx.fill(Path(CGRect(origin: .zero, size: s)), with: .color(.black))
            let gap: CGFloat = 12
            var i: CGFloat = -s.height
            while i < s.width {
                var path = Path()
                path.move(to: CGPoint(x: i, y: 0))
                path.addLine(to: CGPoint(x: i + s.height, y: s.height))
                ctx.stroke(path, with: .color(.white), lineWidth: 3)
                i += gap
            }
        }
    }
}

#Preview {
    TestPatternView()
        .frame(width: 700, height: 520)
}
