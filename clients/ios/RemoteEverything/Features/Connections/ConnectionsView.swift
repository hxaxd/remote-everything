import SwiftUI

/// Profile list with add, switch, and delete. Mirrors Android's `ConnectionsScreen`.
struct ConnectionsView: View {
    @Bindable var model: AppViewModel
    @Bindable var catalogVM: CatalogViewModel
    @State private var showDeleteAlert = false
    @State private var profileToDelete: ConnectionConfig?
    @State private var deletingInstallationId: String?
    @State private var deleteError: String?

    var body: some View {
        List {
            if catalogVM.profiles.isEmpty {
                ContentUnavailableView(
                    "没有连接",
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                    description: Text("扫码或粘贴 setup 链接添加第一台计算机")
                )
            } else {
                ForEach(catalogVM.profiles) { profile in
                    Button {
                        catalogVM.selectProfile(profile)
                        model.activeProfile = profile
                        model.navigationPath.removeAll()
                        model.navigationPath.append(.catalog)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text(profile.gatewayOrigin)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(profile.mode == .lan ? "局域网" : "公网")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if profile.installationId == catalogVM.activeProfile?.installationId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                                    .fontWeight(.bold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(deletingInstallationId != nil)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            profileToDelete = profile
                            showDeleteAlert = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("连接")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    model.navigationPath.append(.setupWizard)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("删除连接", isPresented: $showDeleteAlert, presenting: profileToDelete) { profile in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                deletingInstallationId = profile.installationId
                Task { @MainActor in
                    defer {
                        deletingInstallationId = nil
                        profileToDelete = nil
                    }
                    do {
                        try await catalogVM.deleteProfile(profile)
                        if catalogVM.activeProfile == nil {
                            model.activeProfile = nil
                            model.navigationPath.removeAll()
                        }
                    } catch {
                        deleteError = error.localizedDescription
                    }
                }
            }
            .disabled(deletingInstallationId != nil)
        } message: { profile in
            Text("确定要删除「\(profile.name)」吗？\n此操作将同时清除设备凭据和应用数据。")
        }
        .alert(
            "未能删除连接",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(deleteError ?? "未知错误")
        }
    }
}
