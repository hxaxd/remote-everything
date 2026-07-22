import SwiftUI

struct AppRoot: View {
    @Bindable var model: AppViewModel
    @State private var catalogVM: CatalogViewModel
    @AppStorage("theme_mode") private var themeMode = "system"

    init(model: AppViewModel) {
        self.model = model
        _catalogVM = State(
            initialValue: CatalogViewModel(
                profileStore: model.profileStore,
                identityStore: model.identityStore
            )
        )
    }

    var body: some View {
        NavigationStack(path: $model.navigationPath) {
            Group {
                if model.activeProfile == nil {
                    ConnectionsView(model: model, catalogVM: catalogVM)
                } else {
                    CatalogView(model: model, catalogVM: catalogVM)
                }
            }
            .navigationDestination(for: AppViewModel.AppRoute.self) { route in
                switch route {
                case .catalog:
                    CatalogView(model: model, catalogVM: catalogVM)
                case .connections:
                    ConnectionsView(model: model, catalogVM: catalogVM)
                case .settings:
                    SettingsView(model: model, updater: model.updater)
                case .setupWizard:
                    SetupWizardView(model: model, catalogVM: catalogVM)
                case .remote(let appId, let appName, let openUrl):
                    if let config = model.activeProfile {
                        RemoteWebView(
                            config: config,
                            appId: appId,
                            appName: appName,
                            openUrl: openUrl
                        )
                    }
                }
            }
        }
        .task {
            OrientationController.apply(ClientSettings.shared.globalOrientation)
            await catalogVM.bootstrap()
            if catalogVM.activeProfile != nil {
                model.activeProfile = catalogVM.activeProfile
            }
            await model.updater.checkForUpdatesIfNeeded()
        }
        .preferredColorScheme(preferredColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
