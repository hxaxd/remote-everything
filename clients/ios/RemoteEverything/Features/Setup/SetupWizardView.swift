import SwiftUI

/// Setup wizard orchestrating: scan → parse → pair/verify → activate → ready.
/// Mirrors Android's `SetupWizardScreen`.
struct SetupWizardView: View {
    @Bindable var model: AppViewModel
    @Bindable var catalogVM: CatalogViewModel
    @State private var setupURI = ""
    @State private var showScanner = false
    @State private var wizardState: WizardState = .idle

    enum WizardState: Equatable {
        case idle
        case scanning
        case parsing
        case pairing(String)       // computer name
        case activating(String)     // computer name
        case awaitingApproval(String, String?) // computer name, expires
        case ready(String)          // computer name
        case failed(String, String) // message, action hint
    }

    var body: some View {
        VStack(spacing: 20) {
            switch wizardState {
            case .idle:
                idleView
            case .scanning:
                ScannerView { code in
                    setupURI = code
                    wizardState = .parsing
                }
            case .parsing:
                ProgressView("解析 setup 链接…")
            case .pairing(let name):
                ProgressView("正在与 \(name) 配对…")
            case .activating(let name):
                ProgressView("正在激活 \(name)…")
            case .awaitingApproval(let name, let expires):
                awaitingApprovalView(name: name, expires: expires)
            case .ready(let name):
                readyView(name: name)
            case .failed(let message, let action):
                failedView(message: message, action: action)
            }
        }
        .padding()
        .navigationTitle("添加计算机")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: setupURI) {
            if wizardState == .parsing {
                await processSetupURI(setupURI)
            }
        }
    }

    // MARK: - Subviews

    private var idleView: some View {
        VStack(spacing: 24) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("远程万物")
                .font(.title)
                .fontWeight(.bold)

            Text("扫码或粘贴 remote-everything://setup 链接")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button {
                    showScanner = true
                    wizardState = .scanning
                } label: {
                    Label("扫描二维码", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    if let text = UIPasteboard.general.string,
                       text.contains("remote-everything://setup") {
                        setupURI = text
                        wizardState = .parsing
                    }
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                TextField("或手动输入 setup 链接…", text: $setupURI)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit {
                        if !setupURI.isEmpty {
                            wizardState = .parsing
                        }
                    }
            }
        }
    }

    private func awaitingApprovalView(name: String, expires: String?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.clock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("等待审批")
                .font(.title2)
                .fontWeight(.bold)

            Text("请在 \(name) 上批准此设备的配对请求")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let expires = expires {
                Text("邀请截止: \(expires)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView()
                .padding(.top, 8)

            HStack(spacing: 16) {
                Button("继续检查") {
                    Task {
                        await retryActivation()
                    }
                }
                .buttonStyle(.bordered)

                Button("取消", role: .destructive) {
                    model.setupTransaction?.cancel()
                    wizardState = .idle
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
    }

    private func readyView(name: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("已连接到 \(name)")
                .font(.title2)
                .fontWeight(.bold)

            Text("正在加载应用目录…")
                .foregroundStyle(.secondary)
        }
        .task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            model.navigationPath.removeAll()
            model.navigationPath.append(.catalog)
        }
    }

    private func failedView(message: String, action: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("连接失败")
                .font(.title2)
                .fontWeight(.bold)

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(action)
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack(spacing: 16) {
                Button("重试") {
                    if !setupURI.isEmpty {
                        wizardState = .parsing
                    } else {
                        wizardState = .idle
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("取消") {
                    model.setupTransaction?.cancel()
                    wizardState = .idle
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Logic

    private func processSetupURI(_ uri: String) async {
        let payload: SetupPayload
        do {
            payload = try SetupParser.parse(uri)
        } catch {
            wizardState = .failed(
                error.localizedDescription,
                "请检查 setup 链接是否完整且未被修改"
            )
            return
        }

        let transaction = SetupTransaction(
            settings: model.profileStore,
            identity: model.identityStore,
            deviceName: UIDevice.current.name
        )
        model.setupTransaction = transaction

        wizardState = .pairing(payload.profile.name)

        let result = await transaction.begin(payload)
        wizardState = mapState(result)
    }

    private func retryActivation() async {
        guard let config = model.setupTransaction?.recover() else {
            wizardState = .idle
            return
        }

        wizardState = .activating(config.name)
        let result = await model.setupTransaction!.retryActivation(config: config)
        wizardState = mapState(result)
    }

    private func mapState(_ state: SetupState) -> WizardState {
        switch state {
        case .pairing(let c):
            return .pairing(c.name)
        case .activating(let c, _):
            return .activating(c.name)
        case .awaitingApproval(let c, let expires):
            return .awaitingApproval(c.name, expires)
        case .ready(let c):
            model.activeProfile = c
            catalogVM.activateAfterSetup(c)
            return .ready(c.name)
        case .failed(_, let msg, let action):
            let hint = switch action {
            case .retryPairing: "请确认邀请码仍有效，然后重试配对"
            case .retryActivation: "设备身份已保留，请确认电脑在线后重试激活"
            case .restartSetup: "请重新扫描或粘贴 setup 链接"
            }
            return .failed(msg, hint)
        }
    }
}
