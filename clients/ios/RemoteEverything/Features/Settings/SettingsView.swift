import SwiftUI

/// Settings: theme, display mode, orientation, connection info, about & update.
/// Mirrors Android's `SettingsScreen`.
struct SettingsView: View {
    @Bindable var model: AppViewModel
    @AppStorage("theme_mode") private var themeMode = "system"
    @AppStorage("display_mode") private var displayMode = "phone"
    @AppStorage("global_orientation") private var orientation = "system"
    @State private var updater = AppUpdater()

    var body: some View {
        Form {
            // Orientation
            Section("屏幕方向") {
                Picker("方向", selection: $orientation) {
                    Text("跟随系统").tag("system")
                    Text("竖屏锁定").tag("portrait")
                    Text("横屏锁定").tag("landscape")
                }
                .pickerStyle(.segmented)
            }

            // Display mode
            Section("显示模式") {
                Picker("模式", selection: $displayMode) {
                    Text("手机").tag("phone")
                    Text("电脑").tag("desktop")
                }
                .pickerStyle(.segmented)
            }

            // Theme
            Section("主题") {
                Picker("主题", selection: $themeMode) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            // Connection info
            if let profile = model.activeProfile {
                Section("连接") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(profile.name) · \(profile.mode == .lan ? "局域网" : "公网")")
                            .font(.headline)
                        Text(profile.gatewayOrigin)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button("管理连接") {
                        model.navigationPath.append(.connections)
                    }
                }
            }

            // About & Update — mirrors Android's AboutAndUpdateCard
            Section("关于与更新") {
                VStack(alignment: .leading, spacing: 12) {
                    // Version info
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("远程万物")
                                .font(.headline)
                            Text("版本 \(updater.currentVersion) (\(updater.currentBuild))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // Update status text
                    Text(updateDescription)
                        .font(.subheadline)
                        .foregroundStyle(
                            if case .error = updater.state { Color.red }
                            else { Color.secondary }
                        )

                    // Download progress
                    if case .downloading(_, let progress) = updater.state {
                        ProgressView(value: Double(progress))
                    }

                    // Action button
                    updateActionButton

                    // GitHub project link
                    Button {
                        updater.openGitHubProject()
                    } label: {
                        HStack {
                            Text("查看 GitHub 项目")
                            Image(systemName: "arrow.up.right.square")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("设置")
    }

    // MARK: - Update UI

    private var updateDescription: String {
        switch updater.state {
        case .idle:
            return "从项目正式发布页检查新版本。"
        case .checking:
            return "正在查询最新正式发布版…"
        case .current(let version, let isNewer):
            return isNewer
                ? "当前版本高于最新正式版 \(version)。"
                : "当前已是最新正式版 \(version)。"
        case .available(let release):
            return "发现新版本 \(release.versionName)，可在 GitHub 查看详情。"
        case .downloading(let release, _):
            return "正在下载 \(release.versionName)…"
        case .ready(let release, _):
            return "\(release.versionName) 已下载并通过安全校验。"
        case .error(let detail):
            return detail
        }
    }

    @ViewBuilder
    private var updateActionButton: some View {
        switch updater.state {
        case .idle, .current, .error:
            Button("检查更新") {
                Task { await updater.checkForUpdates() }
            }

        case .checking:
            Button("正在检查…") {}.disabled(true)

        case .available(let release):
            Button("查看正式发布版") {
                updater.openGitHubRelease(release)
            }

        case .downloading:
            Button("正在下载…") {}.disabled(true)

        case .ready:
            Button("安装更新") {
                // On iOS, redirect to GitHub release page
                if case .ready(let release, _) = updater.state {
                    updater.openGitHubRelease(release)
                }
            }
        }
    }
}
