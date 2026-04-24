import SwiftUI

// MARK: - CabinetPosition (プレビュー描画用)

struct CabinetPosition: Hashable {
    let row: Int
    let col: Int
}

// MARK: - LayoutView

struct LayoutView: View {
    @State private var selectedPreset: USBManager.LayoutPreset = .fourByOneLTR
    private let usbManager = USBManager.shared

    private var columns: Int { selectedPreset.columns }
    private var rows: Int { selectedPreset.rows }
    private var cabinetWidth: Int { selectedPreset.cabinetWidth }
    private var cabinetHeight: Int { selectedPreset.cabinetHeight }
    private var scanDirection: USBManager.ScanDirection { selectedPreset.scanDirection }
    private var totalWidth: Int { columns * cabinetWidth }
    private var totalHeight: Int { rows * cabinetHeight }

    var body: some View {
        HStack(spacing: 0) {
            // 左メインエリア (プレビュー)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Layout Preview")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color(hex: "#2d3436"))
                    Spacer()
                    Text("\(columns) × \(rows) cabinets")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                GridPreview(
                    columns: columns,
                    rows: rows,
                    scanDirection: scanDirection
                )
                .frame(height: 280)

                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "aspectratio")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("Output: \(totalWidth) × \(totalHeight) px")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: iconForDirection(scanDirection))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("Direction: \(labelForDirection(scanDirection))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button(action: applyLayout) {
                        Text("Apply Layout")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(usbManager.isConnected ? Color(hex: "#0f3460") : Color(hex: "#b2bec3"))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!usbManager.isConnected)

                    Button(action: resetCards) {
                        Text("Reset")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                            .background(usbManager.isConnected ? Color(hex: "#e94560") : Color(hex: "#b2bec3"))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!usbManager.isConnected)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)

            // 右設定パネル
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSection(title: "Preset") {
                        ForEach(USBManager.LayoutPreset.allCases) { preset in
                            Button(action: { selectedPreset = preset }) {
                                HStack(spacing: 10) {
                                    Image(systemName: iconForDirection(preset.scanDirection))
                                        .font(.system(size: 11))
                                        .frame(width: 14)
                                        .foregroundColor(selectedPreset == preset ? Color(hex: "#0f3460") : .secondary)
                                    Text(preset.rawValue)
                                        .font(.system(size: 12, weight: selectedPreset == preset ? .semibold : .regular))
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

                    SettingsSection(title: "Details") {
                        StatusRow(label: "Columns × Rows", value: "\(columns) × \(rows)")
                        StatusRow(label: "Cabinet", value: "\(cabinetWidth) × \(cabinetHeight) px")
                        StatusRow(label: "Output", value: "\(totalWidth) × \(totalHeight) px")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .frame(width: 240)
            .background(Color.white)
        }
    }

    private func iconForDirection(_ direction: USBManager.ScanDirection) -> String {
        switch direction {
        case .leftToRight: return "arrow.right"
        case .rightToLeft: return "arrow.left"
        case .serpentine: return "arrow.triangle.swap"
        }
    }

    private func labelForDirection(_ direction: USBManager.ScanDirection) -> String {
        switch direction {
        case .leftToRight: return "Left → Right"
        case .rightToLeft: return "Right → Left"
        case .serpentine: return "Serpentine"
        }
    }

    private func applyLayout() {
        USBManager.shared.setLayout(preset: selectedPreset)
    }

    private func resetCards() {
        USBManager.shared.resetReceivingCards()
    }
}

// MARK: - GridPreview (読み取り専用)

struct GridPreview: View {
    let columns: Int
    let rows: Int
    let scanDirection: USBManager.ScanDirection

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

            ZStack {
                ConnectionArrowsView(
                    columns: columns, rows: rows,
                    scanDirection: scanDirection,
                    cellSize: cellSize, spacing: spacing,
                    totalWidth: totalWidth, totalHeight: totalHeight
                )

                VStack(spacing: spacing) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: spacing) {
                            ForEach(0..<columns, id: \.self) { col in
                                PreviewCell(
                                    index: cabinetIndex(row: row, col: col),
                                    cellSize: cellSize
                                )
                            }
                        }
                    }
                }
                .frame(width: totalWidth, height: totalHeight)
            }
            .frame(width: totalWidth, height: totalHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "#e8ecf0"), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    /// スキャン方向に基づくキャビネットの番号 (1始まり)
    private func cabinetIndex(row: Int, col: Int) -> Int {
        let zeroBase: Int
        switch scanDirection {
        case .leftToRight:
            zeroBase = row * columns + col
        case .rightToLeft:
            zeroBase = row * columns + (columns - 1 - col)
        case .serpentine:
            let base = col * rows
            if col % 2 == 0 {
                zeroBase = base + (rows - 1 - row)
            } else {
                zeroBase = base + row
            }
        }
        return zeroBase + 1
    }
}

// MARK: - ConnectionArrowsView

struct ConnectionArrowsView: View {
    let columns: Int
    let rows: Int
    let scanDirection: USBManager.ScanDirection
    let cellSize: CGFloat
    let spacing: CGFloat
    let totalWidth: CGFloat
    let totalHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            let order = scanOrder()
            guard order.count >= 2 else { return }

            for i in 0..<(order.count - 1) {
                let from = cellCenter(row: order[i].row, col: order[i].col)
                let to = cellCenter(row: order[i + 1].row, col: order[i + 1].col)
                drawArrow(context: context, from: from, to: to)
            }
        }
        .allowsHitTesting(false)
        .frame(width: totalWidth, height: totalHeight)
    }

    private func cellCenter(row: Int, col: Int) -> CGPoint {
        let x = CGFloat(col) * (cellSize + spacing) + cellSize / 2
        let y = CGFloat(row) * (cellSize + spacing) + cellSize / 2
        return CGPoint(x: x, y: y)
    }

    private func drawArrow(context: GraphicsContext, from: CGPoint, to: CGPoint) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return }

        let margin: CGFloat = cellSize * 0.35
        let ratio = margin / length
        let start = CGPoint(x: from.x + dx * ratio, y: from.y + dy * ratio)
        let end = CGPoint(x: to.x - dx * ratio, y: to.y - dy * ratio)

        var linePath = Path()
        linePath.move(to: start)
        linePath.addLine(to: end)
        context.stroke(linePath, with: .color(Color(hex: "#e94560").opacity(0.5)), lineWidth: 2)

        let arrowLen: CGFloat = 7
        let arrowAngle: CGFloat = .pi / 6
        let angle = atan2(dy, dx)
        let p1 = CGPoint(
            x: end.x - arrowLen * cos(angle - arrowAngle),
            y: end.y - arrowLen * sin(angle - arrowAngle)
        )
        let p2 = CGPoint(
            x: end.x - arrowLen * cos(angle + arrowAngle),
            y: end.y - arrowLen * sin(angle + arrowAngle)
        )
        var arrowPath = Path()
        arrowPath.move(to: end)
        arrowPath.addLine(to: p1)
        arrowPath.addLine(to: p2)
        arrowPath.closeSubpath()
        context.fill(arrowPath, with: .color(Color(hex: "#e94560").opacity(0.6)))
    }

    private func scanOrder() -> [CabinetPosition] {
        var order = [CabinetPosition]()
        switch scanDirection {
        case .leftToRight:
            for row in 0..<rows {
                for col in 0..<columns {
                    order.append(CabinetPosition(row: row, col: col))
                }
            }
        case .rightToLeft:
            for row in 0..<rows {
                for col in stride(from: columns - 1, through: 0, by: -1) {
                    order.append(CabinetPosition(row: row, col: col))
                }
            }
        case .serpentine:
            for col in 0..<columns {
                if col % 2 == 0 {
                    for row in stride(from: rows - 1, through: 0, by: -1) {
                        order.append(CabinetPosition(row: row, col: col))
                    }
                } else {
                    for row in 0..<rows {
                        order.append(CabinetPosition(row: row, col: col))
                    }
                }
            }
        }
        return order
    }
}

// MARK: - PreviewCell

struct PreviewCell: View {
    let index: Int
    let cellSize: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: "#d6eaf8"))
            VStack(spacing: 2) {
                Text("#\(index)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "#0f3460"))
            }
        }
        .frame(width: cellSize, height: cellSize)
    }
}

// MARK: - Shared Components

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.8))
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(spacing: 10) {
                content
            }
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
