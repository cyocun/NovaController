import SwiftUI

struct ContentView: View {
    @State private var selectedTab: Tab = .brightness
    @ObservedObject private var usbManager = USBManager.shared

    enum Tab {
        case layout, brightness
    }

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                Sidebar(selectedTab: $selectedTab)

                // コンテンツエリア
                Group {
                    switch selectedTab {
                    case .layout:
                        LayoutView()
                    case .brightness:
                        BrightnessView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: "#f5f6fa"))
            }

            // エラーバナー
            if let error = usbManager.lastError {
                ErrorBanner(message: error) {
                    usbManager.lastError = nil
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: usbManager.lastError)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var selectedTab: ContentView.Tab

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack(spacing: 8) {
                Image(systemName: "display.2")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Text("Nova Controller")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Color(hex: "#1a1a2e"))

            // 接続ステータス
            ConnectionStatusView()
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

            Divider()
                .background(Color.white.opacity(0.08))

            // ナビゲーション
            VStack(spacing: 2) {
                NavItem(icon: "square.grid.3x3", title: "レイアウト", isSelected: selectedTab == .layout) {
                    selectedTab = .layout
                }
                NavItem(icon: "sun.max", title: "輝度調整", isSelected: selectedTab == .brightness) {
                    selectedTab = .brightness
                }
            }
            .padding(.top, 12)

            Spacer()
        }
        .frame(width: 200)
        .background(Color(hex: "#16213e"))
    }
}

// MARK: - ConnectionStatusView

struct ConnectionStatusView: View {
    @ObservedObject private var usbManager = USBManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // 状態インジケーター
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.25))
                        .frame(width: 18, height: 18)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                    Text(statusSubtitle)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()
            }

            Button(action: toggleConnection) {
                HStack(spacing: 6) {
                    Image(systemName: usbManager.isConnected ? "xmark.circle" : "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                    Text(usbManager.isConnected ? "切断" : "再接続")
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.1))
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .cornerRadius(10)
    }

    private var statusColor: Color {
        usbManager.isConnected ? Color(hex: "#27ae60") : Color(hex: "#e67e22")
    }

    private var statusTitle: String {
        usbManager.isConnected ? "MSD300 接続中" : "未接続"
    }

    private var statusSubtitle: String {
        usbManager.isConnected ? "USB / CP210x" : "ケーブルを確認"
    }

    private func toggleConnection() {
        if usbManager.isConnected {
            usbManager.stopMonitoring()
        } else {
            usbManager.startMonitoring()
        }
    }
}

// MARK: - NavItem

struct NavItem: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isSelected ? Color(hex: "#0f3460") : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

// MARK: - ErrorBanner

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.white)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(hex: "#e94560"))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 620)
}
