import SwiftUI
import UIKit

struct RemoteApplication: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let accent: String
    let webURL: URL
    let code: String
}

struct ContentView: View {
    @State private var approved = DeviceIdentity.shared.isApproved

    var body: some View {
        Group {
            if approved {
                NavigationStack { CatalogScreen() }
            } else {
                EnrollmentScreen { approved = true }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct EnrollmentScreen: View {
    @StateObject private var model = EnrollmentViewModel()
    let approved: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Agent 远程").font(.system(size: 34, weight: .bold))
            Text("安全连接这台设备").foregroundStyle(.secondary)
            if model.registrationCode.isEmpty && model.error == nil { ProgressView().padding(.top, 20) }
            Text(model.status)
                .foregroundStyle(model.error == nil ? Color.primary : Color.red)
                .padding(.top, 10)
            if !model.registrationCode.isEmpty {
                Text(model.registrationCode)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .tracking(5)
                    .foregroundStyle(.blue)
                    .padding(.vertical, 12)
                Button("复制审批码") { UIPasteboard.general.string = model.registrationCode }
                    .buttonStyle(.borderedProminent)
            }
            Text("把审批码发给服务端管理员。批准前无法访问远程电脑；设备私钥只保存在本机系统密钥库中。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            Spacer()
        }
        .padding(30)
        .background(Color(red: 0.008, green: 0.024, blue: 0.09).ignoresSafeArea())
        .onAppear {
            model.approved = approved
            model.start()
        }
    }
}

@MainActor
final class CatalogModel: ObservableObject {
    @Published var apps: [RemoteApplication] = []
    @Published var error: String?
    @Published var busy: Set<String> = []
    private var loop: Task<Void, Never>?
    private var http: SecureHTTP?

    func start() {
        loop?.cancel()
        loop = Task {
            http = try? SecureHTTP.permanent()
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() { loop?.cancel() }

    func refresh() async {
        guard let http else { error = "安全身份不可用"; return }
        do {
            let result = try await http.json(
                url: AppConfig.appsURL,
                method: "GET",
                headers: ["Authorization": "Bearer \(AppConfig.controlToken)"]
            )
            guard let values = result["apps"] as? [[String: Any]] else { throw NetworkError.invalidResponse }
            apps = values.compactMap { value in
                guard let id = value["id"] as? String,
                      let name = value["name"] as? String,
                      let webValue = value["web_url"] as? String,
                      let webURL = URL(string: webValue),
                      webURL.scheme == "https",
                      webURL.host == AppConfig.gatewayHost else { return nil }
                return RemoteApplication(
                    id: id,
                    name: name,
                    description: value["description"] as? String ?? "",
                    icon: value["icon"] as? String ?? String(name.prefix(1)),
                    accent: value["accent"] as? String ?? "#2563eb",
                    webURL: webURL,
                    code: value["code"] as? String ?? "unknown"
                )
            }
            error = nil
        } catch {
            self.error = "目录暂时不可用"
        }
    }

    func toggle(_ app: RemoteApplication) {
        guard app.code == "ready" || app.code == "stopped", let http else { return }
        let action = app.code == "stopped" ? "start" : "stop"
        busy.insert(app.id)
        Task {
            _ = try? await http.json(
                url: AppConfig.appActionURL(app.id, action),
                method: "POST",
                headers: ["Authorization": "Bearer \(AppConfig.controlToken)"]
            )
            busy.remove(app.id)
            await refresh()
        }
    }
}

struct CatalogScreen: View {
    @StateObject private var model = CatalogModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Agent 远程").font(.system(size: 32, weight: .bold))
                    Text("我的应用").foregroundStyle(.secondary)
                }
                .padding(.bottom, 12)
                if let error = model.error, model.apps.isEmpty {
                    MessageCard(title: error, detail: "无法读取云端应用目录，请检查网络后重试。")
                } else if model.apps.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 50)
                } else {
                    ForEach(model.apps) { app in
                        ApplicationCard(app: app, busy: model.busy.contains(app.id)) {
                            model.toggle(app)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 34)
        }
        .background(Color(red: 0.008, green: 0.024, blue: 0.09).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: RemoteApplication.self) { RemoteScreen(app: $0) }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

struct ApplicationCard: View {
    let app: RemoteApplication
    let busy: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 14) {
                Text(String(app.icon.prefix(4)))
                    .font(.system(size: 21, weight: .bold))
                    .frame(width: 52, height: 52)
                    .background(Color(hex: app.accent), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.system(size: 19, weight: .bold))
                    Text(stateTitle(app.code)).font(.system(size: 13, weight: .medium)).foregroundStyle(stateColor(app.code))
                }
                Spacer()
            }
            if !app.description.isEmpty {
                Text(app.description).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(app.code == "stopped" ? "启动" : "停止", action: toggle)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(busy || (app.code != "ready" && app.code != "stopped"))
                NavigationLink(value: app) {
                    Text("进入").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(Color(red: 0.059, green: 0.09, blue: 0.165), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08)))
    }
}

struct MessageCard: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(red: 0.059, green: 0.09, blue: 0.165), in: RoundedRectangle(cornerRadius: 20))
    }
}

@MainActor
final class RemoteControlModel: ObservableObject {
    @Published var code: String
    @Published var reloadToken = 0
    let app: RemoteApplication
    private var loop: Task<Void, Never>?
    private var http: SecureHTTP?

    init(app: RemoteApplication) {
        self.app = app
        code = app.code
    }

    var title: String {
        switch code {
        case "ready": return "● \(app.name) 已连接"
        case "starting": return "● \(app.name) 正在启动"
        case "stopped": return "● \(app.name) 已关闭"
        case "computer_offline": return "● 电脑离线"
        default: return "● 控制通道不可用"
        }
    }

    var color: Color { stateColor(code) }
    var canToggle: Bool { code == "ready" || code == "stopped" }

    func start() {
        loop?.cancel()
        loop = Task {
            http = try? SecureHTTP.permanent()
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() { loop?.cancel() }

    func refresh() async {
        guard let http else { code = "error"; return }
        let previous = code
        do {
            let result = try await http.json(
                url: AppConfig.appActionURL(app.id, "status"),
                method: "GET",
                headers: ["Authorization": "Bearer \(AppConfig.controlToken)"]
            )
            code = result["code"] as? String ?? "error"
            if code == "ready" && previous != "ready" { reloadToken += 1 }
        } catch {
            code = "error"
        }
    }

    func toggle() {
        guard canToggle, let http else { return }
        let action = code == "stopped" ? "start" : "stop"
        code = action == "start" ? "starting" : "loading"
        Task {
            _ = try? await http.json(
                url: AppConfig.appActionURL(app.id, action),
                method: "POST",
                headers: ["Authorization": "Bearer \(AppConfig.controlToken)"]
            )
            await refresh()
        }
    }
}

struct RemoteScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var control: RemoteControlModel

    init(app: RemoteApplication) {
        _control = StateObject(wrappedValue: RemoteControlModel(app: app))
    }

    var body: some View {
        ZStack(alignment: .top) {
            RemoteWebView(url: control.app.webURL, reloadToken: control.reloadToken).ignoresSafeArea()
            HStack {
                Button { dismiss() } label: {
                    Label("目录", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Text(control.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(control.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: control.toggle) {
                        Image(systemName: "power")
                            .font(.system(size: 25, weight: .semibold))
                            .frame(width: 60, height: 60)
                            .foregroundStyle(.white)
                            .background(Color.blue, in: Circle())
                            .shadow(radius: 12)
                    }
                    .disabled(!control.canToggle)
                    .opacity(control.canToggle ? 1 : 0.55)
                    .padding(20)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { control.start() }
        .onDisappear { control.stop() }
    }
}

private func stateTitle(_ code: String) -> String {
    switch code {
    case "ready": return "● 正在运行"
    case "starting": return "● 正在启动"
    case "stopped": return "● 已停止"
    case "computer_offline": return "● 电脑离线"
    default: return "● 状态不可用"
    }
}

private func stateColor(_ code: String) -> Color {
    switch code {
    case "ready": return .green
    case "starting", "stopped": return .orange
    case "computer_offline": return .gray
    default: return .red
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x2563eb
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
