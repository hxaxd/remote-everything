import SwiftUI

/// S2: the invitation goes in, the node comes out.
///
/// Scan or paste, inspect the destination, name the device and join in one form.
struct PairScreen: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var showingScanner = false

    private var resumingAttempt: Bool {
        if case .failed(.network) = model.pairingPhase { return true }
        return false
    }

    var body: some View {
        let theme = Theme(colorScheme)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gapL) {
                    switch model.pairingPhase {
                    case .pairing:
                        pairingView(theme)
                    case .waitingApproval(let staged):
                        VStack(spacing: Theme.gapM) {
                            ZStack {
                                if model.checkingApprovals.contains(staged.origin) {
                                    ProgressView()
                                } else {
                                    Image(systemName: "clock").font(.title).foregroundStyle(theme.warn)
                                }
                            }.frame(width: 40, height: 40)
                            Text(l10n(MessageKeys.PAIR_WAITING_APPROVAL)).font(Theme.headline)
                            Text(staged.nodeName).font(Theme.body)
                            Button(l10n(MessageKeys.ACTION_RETRY)) {
                                Task { await model.resumeStagedSetups(origin: staged.origin) }
                            }
                            .buttonStyle(ActionButtonStyle(height: 44))
                            .disabled(model.checkingApprovals.contains(staged.origin))
                            Button(l10n(MessageKeys.ACTION_BACK)) { model.leaveAddNode(); dismiss() }
                        }
                        .frame(maxWidth: .infinity)
                    case .idle, .failed:
                        inputView(theme)
                        if let invitation = model.invitation {
                            confirmView(theme, invitation: invitation)
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
        .interactiveDismissDisabled(model.pairingPhase == .pairing)
        .fullScreenCover(isPresented: $showingScanner) {
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
            Button {
                showingScanner = true
            } label: {
                Text(l10n(MessageKeys.PAIR_SCAN))
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassPanel(cornerRadius: Theme.radiusControl, tint: theme.accent.opacity(0.24))
            TextField(l10n(MessageKeys.PAIR_INPUT_HINT), text: Binding(
                get: { model.addNodeText },
                set: { model.addNodeText = $0; model.parseInvitation($0) }
            ), axis: .vertical)
                .font(Theme.body)
                .lineLimit(3...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textFieldStyle(.plain)
                .padding(Theme.gapM)
                .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
                .glassPanel(cornerRadius: Theme.radiusControl, stroked: false)
                .accessibilityIdentifier("pair.invitation")
            if model.invitationError != nil {
                Text(l10n(MessageKeys.PAIR_BAD_INVITATION))
                    .font(Theme.caption)
                    .foregroundStyle(theme.danger)
            }
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
                    .textFieldStyle(.roundedBorder)
                    .disabled(resumingAttempt)
                if model.deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(l10n(MessageKeys.PAIR_DEVICE_NAME_REQUIRED))
                        .font(Theme.caption)
                        .foregroundStyle(theme.danger)
                }
            }
            if case .failed(let failure) = model.pairingPhase {
                Text(ErrorText.text(for: failure))
                    .font(Theme.body)
                    .foregroundStyle(theme.danger)
            }
            Button {
                Task { await model.confirmPairing() }
            } label: {
                Text(l10n(MessageKeys.PAIR_ACTION_JOIN))
            }
            .buttonStyle(ActionButtonStyle(height: 48))
            .accessibilityIdentifier("pair.join")
            .disabled(model.deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(Theme.gapM)
        .glassPanel(cornerRadius: 16)
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
}
