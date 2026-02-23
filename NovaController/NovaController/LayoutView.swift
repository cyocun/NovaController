import SwiftUI

// MARK: - CabinetPosition

struct CabinetPosition: Hashable {
    let row: Int
    let col: Int
}

// MARK: - LayoutView

struct LayoutView: View {
    @State private var columns: Int = 4
    @State private var rows: Int = 1
    @State private var cabinetWidth: Int = 128
    @State private var cabinetHeight: Int = 128
    @State private var selectedCabinet: CabinetPosition? = nil
    @State private var enabledCabinets: Set<CabinetPosition> = []
    @State private var scanDirection: USBManager.ScanDirection = .leftToRight

    var totalResolution: (width: Int, height: Int) {
        guard enabledCabinets.count > 0 else { return (0, 0) }
        return (columns * cabinetWidth, rows * cabinetHeight)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左メインエリア
            VStack(alignment: .leading, spacing: 16) {
                // ヘッダー
                HStack {
                    Text("キャビネット配置")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color(hex: "#2d3436"))
                    Spacer()
                    Text("合計: \(enabledCabinets.count) / \(columns * rows) キャビネット")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                // グリッドエディター
                GridEditorView(
                    columns: columns,
                    rows: rows,
                    scanDirection: scanDirection,
                    selectedCabinet: $selectedCabinet,
                    enabledCabinets: $enabledCabinets
                )
                .frame(height: 280)

                // フッター - 出力解像度 + スキャン方向表示
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "aspectratio")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("出力解像度: \(totalResolution.width) x \(totalResolution.height) px")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: scanDirectionIcon)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("方向: \(scanDirection.rawValue)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                // 適用ボタン
                Button(action: applyLayout) {
                    Text("レイアウトを適用")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: "#0f3460"))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .frame(maxWidth: .infinity)

            // 右設定パネル
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("設定")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    SettingsSection(title: "グリッドサイズ") {
                        StepperField(label: "列数", value: $columns, range: 1...16)
                        StepperField(label: "行数", value: $rows, range: 1...16)
                    }

                    SettingsSection(title: "キャビネットサイズ (px)") {
                        StepperField(label: "幅", value: $cabinetWidth, range: 32...512, step: 8)
                        StepperField(label: "高さ", value: $cabinetHeight, range: 32...512, step: 8)
                    }

                    SettingsSection(title: "スキャン方向") {
                        ForEach(USBManager.ScanDirection.allCases) { direction in
                            Button(action: { scanDirection = direction }) {
                                HStack {
                                    Image(systemName: iconForDirection(direction))
                                        .font(.system(size: 11))
                                        .frame(width: 16)
                                    Text(direction.rawValue)
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    if scanDirection == direction {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(Color(hex: "#0f3460"))
                                    }
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(
                                    scanDirection == direction
                                        ? Color(hex: "#d6eaf8")
                                        : Color.clear
                                )
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let selected = selectedCabinet {
                        SettingsSection(title: "選択中のキャビネット") {
                            HStack {
                                Text("位置")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("(\(selected.col + 1), \(selected.row + 1))")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            HStack {
                                Text("状態")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(enabledCabinets.contains(selected) ? "有効" : "無効")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(enabledCabinets.contains(selected) ? Color(hex: "#27ae60") : .secondary)
                            }
                        }
                    }

                    SettingsSection(title: "クイック操作") {
                        Button(action: enableAll) {
                            Text("全て有効")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(SmallButtonStyle(color: Color(hex: "#0f3460")))

                        Button(action: disableAll) {
                            Text("全て無効")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(SmallButtonStyle(color: Color(hex: "#b2bec3")))
                    }
                }
                .padding(16)
            }
            .frame(width: 200)
            .background(Color.white)
        }
    }

    private var scanDirectionIcon: String {
        iconForDirection(scanDirection)
    }

    private func iconForDirection(_ direction: USBManager.ScanDirection) -> String {
        switch direction {
        case .leftToRight: return "arrow.right"
        case .rightToLeft: return "arrow.left"
        case .topToBottom: return "arrow.down"
        }
    }

    private func applyLayout() {
        USBManager.shared.setLayout(
            columns: columns,
            rows: rows,
            cabinetWidth: cabinetWidth,
            cabinetHeight: cabinetHeight,
            enabled: enabledCabinets
        )
    }

    private func enableAll() {
        for r in 0..<rows {
            for c in 0..<columns {
                enabledCabinets.insert(CabinetPosition(row: r, col: c))
            }
        }
    }

    private func disableAll() {
        enabledCabinets.removeAll()
    }
}

// MARK: - GridEditorView

struct GridEditorView: View {
    let columns: Int
    let rows: Int
    let scanDirection: USBManager.ScanDirection
    @Binding var selectedCabinet: CabinetPosition?
    @Binding var enabledCabinets: Set<CabinetPosition>

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 4
            let availableWidth = geometry.size.width - CGFloat(columns - 1) * spacing
            let availableHeight = geometry.size.height - CGFloat(rows - 1) * spacing
            let cellWidth = min(availableWidth / CGFloat(columns), 80)
            let cellHeight = min(availableHeight / CGFloat(rows), 80)
            let cellSize = min(cellWidth, cellHeight)

            let totalWidth = cellSize * CGFloat(columns) + spacing * CGFloat(columns - 1)
            let totalHeight = cellSize * CGFloat(rows) + spacing * CGFloat(rows - 1)

            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<columns, id: \.self) { col in
                            let pos = CabinetPosition(row: row, col: col)
                            let index = cabinetIndex(row: row, col: col)
                            CabinetCell(
                                position: pos,
                                index: index,
                                isSelected: selectedCabinet == pos,
                                isEnabled: enabledCabinets.contains(pos),
                                cellSize: cellSize
                            ) {
                                if selectedCabinet == pos {
                                    if enabledCabinets.contains(pos) {
                                        enabledCabinets.remove(pos)
                                    } else {
                                        enabledCabinets.insert(pos)
                                    }
                                } else {
                                    selectedCabinet = pos
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: totalWidth, height: totalHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(hex: "#e8ecf0"))
        .cornerRadius(12)
    }

    /// スキャン方向に基づくキャビネットの番号を計算
    private func cabinetIndex(row: Int, col: Int) -> Int {
        switch scanDirection {
        case .leftToRight:
            return row * columns + col
        case .rightToLeft:
            return row * columns + (columns - 1 - col)
        case .topToBottom:
            return col * rows + row
        }
    }
}

// MARK: - CabinetCell

struct CabinetCell: View {
    let position: CabinetPosition
    let index: Int
    let isSelected: Bool
    let isEnabled: Bool
    let cellSize: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isSelected && isEnabled {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(hex: "#0f3460"))
                    VStack(spacing: 2) {
                        Text("#\(index)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        if cellSize > 50 {
                            Text("\(position.col + 1),\(position.row + 1)")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                } else if isSelected && !isEnabled {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(hex: "#dfe6e9"))
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(hex: "#0f3460"), lineWidth: 2)
                } else if !isSelected && isEnabled {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(hex: "#d6eaf8"))
                    VStack(spacing: 2) {
                        Text("#\(index)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(hex: "#0f3460"))
                        if cellSize > 50 {
                            Text("\(position.col + 1),\(position.row + 1)")
                                .font(.system(size: 8))
                                .foregroundColor(Color(hex: "#0f3460").opacity(0.6))
                        }
                    }
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.6))
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#b2bec3"))
                }
            }
            .frame(width: cellSize, height: cellSize)
            .animation(.easeInOut(duration: 0.15), value: isSelected)
            .animation(.easeInOut(duration: 0.15), value: isEnabled)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared Components

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 8) {
                content
            }
            .padding(12)
            .background(Color(hex: "#f5f6fa"))
            .cornerRadius(8)
        }
    }
}

struct StepperField: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#2d3436"))

            Spacer()

            HStack(spacing: 0) {
                Button(action: { if value - step >= range.lowerBound { value -= step } }) {
                    Text("\u{2212}")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(Color(hex: "#dfe6e9"))
                }
                .buttonStyle(.plain)

                Text("\(value)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(width: 36)
                    .multilineTextAlignment(.center)

                Button(action: { if value + step <= range.upperBound { value += step } }) {
                    Text("\u{FF0B}")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(Color(hex: "#dfe6e9"))
                }
                .buttonStyle(.plain)
            }
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(hex: "#b2bec3"), lineWidth: 1)
            )
        }
    }
}

struct SmallButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(color)
            .cornerRadius(6)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

#Preview {
    LayoutView()
}
