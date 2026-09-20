import SwiftUI
import UIKit

/// S5: language, appearance, connections, updates, and what this build is.
struct SettingsScreen: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var forgetting: Identity?
    @State private var copied: String?
    @State private var copiedTask: Task<Void, Never>?

    var body: some View {
        let theme = Theme(colorScheme)
        NavigationStack {
            List {
                languageSection(theme)
                appearanceSection(theme)
                connectionsSection(theme)
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
            .overlay(alignment: .top) {
                if let copied {
                    Text(copied)
                        .font(Theme.caption)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, Theme.gapM)
                        .padding(.vertical, Theme.gapS)
                        .background(Capsule().fill(theme.bgElevated))
                        .padding(.top, Theme.gapL)
                        .transition(.opacity)
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
            Button(l10n(MessageKeys.ACTION_CONFIRM), role: .destructive) {
                let origin = identity.origin
                forgetting = nil
                Task { await model.forget(origin: origin) }
            }
            Button(l10n(MessageKeys.ACTION_CANCEL), role: .cancel) {
                forgetting = nil
            }
        } message: { identity in
            Text(l10n(MessageKeys.SETTINGS_FORGET_CONFIRM))
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
        let trouble = model.troubleFor(identity.origin)
        let troubleReason: String? = {
            if let trouble {
                return l10n(trouble.kind.messageKey)
            }
            if let condition = model.identityConditions[identity.origin], condition != .ok {
                return conditionText(condition)
            }
            return nil
        }()

        return VStack(alignment: .leading, spacing: Theme.gapS) {
            HStack(alignment: .center, spacing: Theme.gapS) {
                // What the connection is, and what it is called, one under the other
                // and the same size, each a tap away from the clipboard: the address
                // is what a person reads, the name is what they send with it.
                VStack(alignment: .leading, spacing: 2) {
                    copyable(identity.origin, display: displayAddress(identity.origin), theme: theme, colour: theme.textPrimary)
                    copyable(identity.deviceName, theme: theme, colour: theme.textSecondary)
                }
                Spacer(minLength: Theme.gapS)
                Button {
                    forgetting = identity
                } label: {
                    Text(l10n(MessageKeys.SETTINGS_FORGET))
                        .font(Theme.body)
                        .foregroundStyle(theme.danger)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
            }
            if let troubleReason {
                HStack(alignment: .center, spacing: Theme.gapS) {
                    Text(troubleReason)
                        .font(Theme.caption)
                        .foregroundStyle(theme.danger)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Theme.gapS)
                    if trouble != nil {
                        Button {
                            let report = model.troubleReport(identity: identity)
                            if !report.isEmpty { copy(report) }
                        } label: {
                            Text(l10n(MessageKeys.SETTINGS_COPY_ERROR))
                                .font(Theme.caption)
                                .foregroundStyle(theme.accent)
                                .lineLimit(1)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(Theme.gapM)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(theme.hairline, lineWidth: Theme.hairlineWidth)
                )
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// A line of a connection that is also a thing to take away.
    private func copyable(_ value: String, display: String? = nil, theme: Theme, colour: Color, font: Font = Theme.body) -> some View {
        Text(display ?? value)
            .font(font)
            .foregroundStyle(colour)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentShape(Rectangle())
            .onTapGesture { copy(value) }
    }

    /// The clipboard has no opinion about what happened, so this screen says so —
    /// once, briefly, the way a screen says everything else it has to say.
    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        copiedTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { copied = l10n(MessageKeys.ACTION_COPIED) }
        copiedTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { copied = nil }
        }
    }

    /// Three plain rows, the way a page about the build reads: what this app is, what
    /// it speaks, and what this phone calls itself. Nothing is boxed, because none of it
    /// is a list — and the version number is the update check, without a button saying so.
    private func aboutSection(_ theme: Theme) -> some View {
        Section {
            versionRow(theme)
            aboutRow(
                l10n(MessageKeys.SETTINGS_PROTOCOL_VERSION),
                "\(AppVersion.protocolVersion)",
                theme: theme
            )
            aboutRow(
                l10n(MessageKeys.SETTINGS_DEVICE_NAME),
                AppModel.defaultDeviceName(),
                theme: theme,
                onValue: { copy(AppModel.defaultDeviceName()) }
            )
        } header: {
            Text(l10n(MessageKeys.SETTINGS_ABOUT))
                .foregroundStyle(theme.textSecondary)
        }
    }

    /**
     * The version line of "about this build", which is also the update check.
     *
     * Short outcomes ("checking…", "up to date") live on the same line between the
     * label and the version without shifting the rows beneath it. An available update
     * highlights the new version on the right, and detailed store instructions only
     * appear below when there is an update to act on.
     */
    private func versionRow(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(l10n(MessageKeys.SETTINGS_VERSION))
                    .font(Theme.body)
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: Theme.gapM)
                Text(versionValueText)
                    .font(Theme.caption)
                    .foregroundStyle(versionValueColor(theme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let detail = versionDetailText {
                Text(detail)
                    .font(Theme.caption)
                    .foregroundStyle(versionDetailColor(theme))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await model.checkForUpdates() }
        }
    }

    private var currentVersionText: String {
        "\(AppVersion.versionName) (\(AppVersion.buildNumber))"
    }

    private var versionValueText: String {
        switch model.updateState {
        case .idle:
            return currentVersionText
        case .checking:
            return "\(l10n(MessageKeys.SETTINGS_UPDATES_CHECKING)) · \(currentVersionText)"
        case .result(.upToDate):
            return "\(l10n(MessageKeys.SETTINGS_UPDATES_NONE)) · \(currentVersionText)"
        case .result(.available(let versionName, let buildNumber)):
            return l10n(MessageKeys.SETTINGS_UPDATES_AVAILABLE, versionName, buildNumber)
        case .result(.protocolChanged), .result(.unreachable):
            return currentVersionText
        }
    }

    private func versionValueColor(_ theme: Theme) -> Color {
        switch model.updateState {
        case .result(.available):
            return theme.accent
        case .result(.protocolChanged):
            return theme.danger
        default:
            return theme.textSecondary
        }
    }

    private var versionDetailText: String? {
        switch model.updateState {
        case .idle, .checking, .result(.upToDate):
            return nil
        case .result(.available):
            return l10n(MessageKeys.SETTINGS_UPDATES_STORE_HINT)
        case .result(.protocolChanged):
            return "\(l10n(MessageKeys.SETTINGS_UPDATES_PROTOCOL)) \(l10n(MessageKeys.SETTINGS_UPDATES_STORE_HINT))"
        case .result(.unreachable):
            return l10n(MessageKeys.SETTINGS_UPDATES_FAILED)
        }
    }

    private func versionDetailColor(_ theme: Theme) -> Color {
        switch model.updateState {
        case .result(.protocolChanged), .result(.unreachable):
            return theme.danger
        default:
            return theme.textSecondary
        }
    }

    /**
     * One line of "about this build": what it is on the left, what it is on the right,
     * and — where there is something a person can do with the value — the whole row is
     * what they tap. No button, because the value is the thing.
     */
    private func aboutRow(
        _ label: String,
        _ value: String,
        theme: Theme,
        onValue: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Theme.body)
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: Theme.gapM)
            Text(value)
                .font(Theme.caption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let onValue, !value.isEmpty {
                onValue()
            }
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
