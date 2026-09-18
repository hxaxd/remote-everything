import SwiftUI

/// S5: language, appearance, connections, updates, and what this build is.
struct SettingsScreen: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var forgetting: Identity?

    var body: some View {
        let theme = Theme(colorScheme)
        NavigationStack {
            List {
                languageSection(theme)
                appearanceSection(theme)
                connectionsSection(theme)
                updateSection(theme)
                aboutSection(theme)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .navigationTitle(l10n(MessageKeys.SETTINGS_TITLE))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(l10n(MessageKeys.ACTION_DONE)) { dismiss() }
                }
            }
        }
        .alert(
            l10n(MessageKeys.SETTINGS_FORGET),
            isPresented: Binding(
                get: { forgetting != nil },
                set: { presented in
                    if !presented { forgetting = nil }
                }
            ),
            presenting: forgetting
        ) { identity in
            Button(l10n(MessageKeys.SETTINGS_FORGET), role: .destructive) {
                let origin = identity.origin
                forgetting = nil
                Task { await model.forget(origin: origin) }
            }
            Button(l10n(MessageKeys.ACTION_CANCEL), role: .cancel) {
                forgetting = nil
            }
        } message: { identity in
            Text(l10n(MessageKeys.SETTINGS_FORGET_CONFIRM, model.nodeCount(forIdentity: identity)))
        }
    }

    // MARK: - Sections

    private func languageSection(_ theme: Theme) -> some View {
        Section {
            Picker(l10n(MessageKeys.SETTINGS_LANGUAGE), selection: Binding(
                get: { model.settings.language },
                set: { model.setLanguage($0) }
            )) {
                Text(l10n(MessageKeys.SETTINGS_LANGUAGE_SYSTEM)).tag(Language.system)
                Text(l10n(MessageKeys.LANGUAGE_ZH)).tag(Language.zh)
                Text(l10n(MessageKeys.LANGUAGE_EN)).tag(Language.en)
            }
            .pickerStyle(.segmented)
        } header: {
            Text(l10n(MessageKeys.SETTINGS_LANGUAGE))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func appearanceSection(_ theme: Theme) -> some View {
        Section {
            Picker(l10n(MessageKeys.SETTINGS_APPEARANCE), selection: Binding(
                get: { model.settings.appearance },
                set: { model.setAppearance($0) }
            )) {
                Text(l10n(MessageKeys.SETTINGS_APPEARANCE_SYSTEM)).tag(Appearance.system)
                Text(l10n(MessageKeys.SETTINGS_APPEARANCE_LIGHT)).tag(Appearance.light)
                Text(l10n(MessageKeys.SETTINGS_APPEARANCE_DARK)).tag(Appearance.dark)
            }
            .pickerStyle(.segmented)
        } header: {
            Text(l10n(MessageKeys.SETTINGS_APPEARANCE))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func connectionsSection(_ theme: Theme) -> some View {
        Section {
            if model.identities.isEmpty {
                Text(l10n(MessageKeys.SETTINGS_NO_IDENTITIES))
                    .font(Theme.body)
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(model.identities) { identity in
                    connectionRow(theme, identity: identity)
                }
            }
        } header: {
            Text(l10n(MessageKeys.SETTINGS_IDENTITIES))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func connectionRow(_ theme: Theme, identity: Identity) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            Text(displayAddress(identity.origin))
                .font(Theme.headline)
                .foregroundStyle(theme.textPrimary)
            if let condition = model.identityConditions[identity.origin], condition != .ok {
                Text(conditionText(condition))
                    .font(Theme.caption)
                    .foregroundStyle(condition == .unauthorized ? theme.warn : theme.danger)
            }
            row(l10n(MessageKeys.SETTINGS_NODES_COUNT), "\(model.nodeCount(forIdentity: identity))", theme: theme, mono: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n(MessageKeys.SETTINGS_CERTIFICATE_FINGERPRINT))
                    .font(Theme.footnote)
                    .foregroundStyle(theme.textTertiary)
                Text(groupedFingerprint(identity.certFingerprint))
                    .font(Theme.mono)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                forgetting = identity
            } label: {
                Text(l10n(MessageKeys.SETTINGS_FORGET))
                    .font(Theme.body)
                    .foregroundStyle(theme.danger)
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.gapS / 2)
        }
        .padding(.vertical, Theme.gapS)
    }

    private func row(_ title: String, _ value: String, theme: Theme, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.footnote)
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .font(mono ? Theme.mono : Theme.body)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func updateSection(_ theme: Theme) -> some View {
        Section {
            HStack {
                Text(l10n(MessageKeys.SETTINGS_UPDATES_CURRENT, AppVersion.versionName, AppVersion.buildNumber))
                    .font(Theme.caption)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button {
                    Task { await model.checkForUpdates() }
                } label: {
                    Text(l10n(MessageKeys.SETTINGS_UPDATES_CHECK))
                        .font(Theme.caption)
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(model.updateState == .checking)
            }
            updateResultView(theme)
        } header: {
            Text(l10n(MessageKeys.SETTINGS_UPDATES))
                .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private func updateResultView(_ theme: Theme) -> some View {
        switch model.updateState {
        case .idle:
            EmptyView()
        case .checking:
            Text(l10n(MessageKeys.SETTINGS_UPDATES_CHECKING))
                .font(Theme.caption)
                .foregroundStyle(theme.textSecondary)
        case .result(.upToDate):
            Text(l10n(MessageKeys.SETTINGS_UPDATES_NONE))
                .font(Theme.caption)
                .foregroundStyle(theme.textSecondary)
        case .result(.available(let versionName, let buildNumber)):
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n(MessageKeys.SETTINGS_UPDATES_AVAILABLE, versionName, buildNumber))
                    .font(Theme.body)
                    .foregroundStyle(theme.textPrimary)
                Text(l10n(MessageKeys.SETTINGS_UPDATES_STORE_HINT))
                    .font(Theme.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        case .result(.protocolChanged):
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n(MessageKeys.SETTINGS_UPDATES_PROTOCOL))
                    .font(Theme.body)
                    .foregroundStyle(theme.warn)
                Text(l10n(MessageKeys.SETTINGS_UPDATES_STORE_HINT))
                    .font(Theme.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        case .result(.unreachable):
            Text(ErrorText.network)
                .font(Theme.caption)
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func aboutSection(_ theme: Theme) -> some View {
        Section {
            row(l10n(MessageKeys.SETTINGS_VERSION), "\(AppVersion.versionName) (\(AppVersion.buildNumber))", theme: theme, mono: false)
            row(l10n(MessageKeys.SETTINGS_PROTOCOL_VERSION), "\(AppVersion.protocolVersion)", theme: theme, mono: false)
            row(l10n(MessageKeys.SETTINGS_DEVICE_NAME), AppModel.defaultDeviceName(), theme: theme, mono: false)
        } header: {
            Text(l10n(MessageKeys.SETTINGS_ABOUT))
                .foregroundStyle(theme.textSecondary)
        }
    }

    // MARK: - Helpers

    /// The address an operator knows: host and port, without the scheme.
    private func displayAddress(_ origin: String) -> String {
        var value = origin
        if let range = value.range(of: "://") {
            value = String(value[range.upperBound...])
        }
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    private func conditionText(_ condition: IdentityCondition) -> String {
        switch condition {
        case .ok: return ""
        case .unauthorized: return l10n(MessageKeys.IDENTITY_UNAUTHORIZED)
        case .needsPairing: return l10n(MessageKeys.IDENTITY_NEEDS_PAIRING)
        case .unreachable: return l10n(MessageKeys.NODE_OFFLINE)
        }
    }
}
