import SwiftUI

/// Application catalog with pull-to-refresh, start/stop, drag-to-reorder, and offline state.
/// Mirrors Android's `CatalogScreen`.
struct CatalogView: View {
    @Bindable var model: AppViewModel
    @Bindable var catalogVM: CatalogViewModel
    @State private var isRefreshing = false
    @State private var message: String?

    var body: some View {
        Group {
            switch catalogVM.catalogState {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载应用目录…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .ready(let snapshot):
                if snapshot.computerConnected {
                    appList(snapshot)
                } else {
                    ContentUnavailableView(
                        "电脑离线",
                        systemImage: "wifi.slash",
                        description: Text("请确认电脑已开机且网络正常")
                    )
                }
            case .error(let detail):
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(detail)
                } actions: {
                    Button("重试") {
                        catalogVM.startPolling()
                    }
                }
            }
        }
        .navigationTitle(catalogVM.activeProfile?.name ?? "应用")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    model.navigationPath.append(.connections)
                } label: {
                    Image(systemName: "list.bullet")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    model.navigationPath.append(.settings)
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
        .onDisappear {
            // Keep polling while in catalog subtree
        }
    }

    // MARK: - App List

    @ViewBuilder
    private func appList(_ snapshot: CatalogSnapshot) -> some View {
        List {
            ForEach(snapshot.apps) { app in
                AppCardView(
                    app: app,
                    onOpen: {
                        model.navigationPath.append(
                            .remote(appId: app.id, openUrl: app.openUrl)
                        )
                    },
                    onToggle: {
                        let action = app.code == .stopped ? "start" : "stop"
                        Task {
                            await catalogVM.controlApp(appId: app.id, action: action)
                        }
                    }
                )
            }
        }
        .refreshable {
            await catalogVM.refreshCatalog()
        }
    }
}

// MARK: - App Card

struct AppCardView: View {
    let app: RemoteApp
    let onOpen: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Text(app.icon)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Color(hex: app.accent).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.body)
                    .fontWeight(.medium)
                if !app.description.isEmpty {
                    Text(app.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                StatusChipView(code: app.code)
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    Image(systemName: app.code == .stopped ? "play.fill" : "stop.fill")
                        .font(.caption)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .tint(app.code == .stopped ? .green : .red)

                Button(action: onOpen) {
                    Image(systemName: "arrow.up.left.square")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .disabled(app.code != .ready)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Status Chip

struct StatusChipView: View {
    let code: RemoteApp.AppCode

    var body: some View {
        Text(code.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(code.color.opacity(0.15))
            .foregroundStyle(code.color)
            .clipShape(Capsule())
    }
}

extension RemoteApp.AppCode {
    var displayName: String {
        switch self {
        case .ready:    return "运行中"
        case .starting: return "启动中"
        case .stopping: return "停止中"
        case .stopped:  return "已停止"
        }
    }

    var color: Color {
        switch self {
        case .ready:    return .green
        case .starting: return .orange
        case .stopping: return .orange
        case .stopped:  return .secondary
        }
    }
}

// MARK: - Hex Color Support

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
