import SwiftUI

/// S2: the invitation goes in, the node comes out.
///
/// Three steps in one sheet — input, confirm, pairing — and the sheet closes
/// itself when the gateway has answered. Nothing local is left behind if the
/// user leaves before confirming; once the pairing request is out the invitation
/// may already be spent, so there is no cancel from there, only the answer.
struct AddNodeScreen: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var showingScanner = false

    var body: some View {
        let theme = Theme(colorScheme)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gapL) {
                    switch model.pairingPhase {
                    case .pairing:
                        pairingView(theme)
                    case .failed(let failure):
                        failureView(theme, failure: failure)
                    case .idle:
                        if let invitation = model.invitation {
                            confirmView(theme, invitation: invitation)
                        } else {
                            inputView(theme)
                        }
                    }
                }
                .padding(Theme.gapM)
                .frame(maxWidth: Theme.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .background(theme.bg)
            .navigationTitle(l10n(MessageKeys.PAIR_TITLE))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(l10n(MessageKeys.ACTION_CANCEL)) {
                        model.cancelAddNode()
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showingScanner) {
            ScannerScreen { code in
                showingScanner = false
                model.addNodeText = code
                model.parseInvitation(code)
            }
        }
        .onAppear {
            if model.deviceNameDraft.isEmpty {
                model.deviceNameDraft = AppModel.defaultDeviceName()
            }
        }
    }

    // MARK: - Steps

    private func inputView(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            Text(l10n(MessageKeys.PAIR_INPUT_HINT))
                .font(Theme.body)
                .foregroundStyle(theme.textSecondary)
            TextField(l10n(MessageKeys.PAIR_INPUT_HINT), text: Binding(
                get: { model.addNodeText },
                set: { model.addNodeText = $0; model.parseInvitation($0) }
            ), axis: .vertical)
                .font(Theme.body)
                .lineLimit(2...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(Theme.gapS + 2)
                .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                        .strokeBorder(model.invitationError == nil ? theme.hairline : theme.danger, lineWidth: Theme.hairlineWidth)
                )
            if model.invitationError != nil {
                Text(l10n(MessageKeys.PAIR_BAD_INVITATION))
                    .font(Theme.caption)
                    .foregroundStyle(theme.danger)
            }
            Button {
                showingScanner = true
            } label: {
                HStack(spacing: Theme.gapS) {
                    Image(systemName: "qrcode.viewfinder")
                    Text(l10n(MessageKeys.PAIR_SCAN))
                }
                .font(Theme.body)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, Theme.gapM)
                .padding(.vertical, Theme.gapS)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: Theme.hairlineWidth)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func confirmView(_ theme: Theme, invitation: SetupURI.Invitation) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapL) {
            Text(l10n(MessageKeys.PAIR_CONFIRM_BODY, invitation.origin, invitation.nodeName))
                .font(Theme.body)
                .foregroundStyle(theme.textPrimary)
            VStack(alignment: .leading, spacing: Theme.gapS) {
                Text(l10n(MessageKeys.PAIR_DEVICE_NAME))
                    .font(Theme.caption)
                    .foregroundStyle(theme.textSecondary)
                TextField(l10n(MessageKeys.PAIR_DEVICE_NAME), text: $model.deviceNameDraft)
                    .font(Theme.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(Theme.gapS + 2)
                    .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                            .strokeBorder(theme.hairline, lineWidth: Theme.hairlineWidth)
                    )
            }
            Button {
                Task { await model.confirmPairing() }
            } label: {
                Text(l10n(MessageKeys.PAIR_ACTION_JOIN))
                    .font(Theme.body)
                    .foregroundStyle(theme.accentOnBg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.gapS + 4)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func pairingView(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            HStack(spacing: Theme.gapS) {
                ProgressView()
                Text(l10n(MessageKeys.PAIR_WORKING))
                    .font(Theme.body)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func failureView(_ theme: Theme, failure: PairingFailure) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            Text(ErrorText.text(for: failure))
                .font(Theme.body)
                .foregroundStyle(failure.isNetwork ? theme.textPrimary : theme.danger)
            HStack(spacing: Theme.gapM) {
                if failure.isNetwork {
                    Button {
                        Task { await model.retryPairing() }
                    } label: {
                        Text(l10n(MessageKeys.ACTION_RETRY))
                            .font(Theme.body)
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, Theme.gapL)
                            .padding(.vertical, Theme.gapS)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                                    .strokeBorder(theme.hairline, lineWidth: Theme.hairlineWidth)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    model.finishPairingSheet()
                    dismiss()
                } label: {
                    Text(l10n(MessageKeys.ACTION_DONE))
                        .font(Theme.body)
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, Theme.gapL)
                        .padding(.vertical, Theme.gapS)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                                .strokeBorder(theme.hairline, lineWidth: Theme.hairlineWidth)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension PairingFailure {
    /// A network failure is worth retrying with the same attempt; a refusal is
    /// the gateway's answer and retrying it changes nothing.
    var isNetwork: Bool {
        if case .network = self { return true }
        return false
    }
}
