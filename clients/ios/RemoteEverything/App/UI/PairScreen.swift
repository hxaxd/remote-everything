import SwiftUI

/// S2: the invitation goes in, the node comes out.
///
/// Scan or paste, inspect the destination, name the device and join in one form.
struct PairScreen: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

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
            // One way out, the way Android has one back arrow: leaving never
            // cancels — a pairing in flight answers behind the home banner.
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        model.closePairPresentation()
                    } label: {
                        Label(l10n(MessageKeys.ACTION_BACK), systemImage: "chevron.left")
                    }
                    .disabled(model.pairingPhase == .pairing)
                }
            }
        }
        .interactiveDismissDisabled(model.pairingPhase == .pairing)
        .sheet(isPresented: $showingScanner) {
            ScannerScreen { code in
                showingScanner = false
                model.addNodeText = code
                model.parseInvitation(code)
            }
            .onAppear {
                if model.deviceNameDraft.isEmpty {
                    model.deviceNameDraft = AppModel.defaultDeviceName()
                }
            }
    }

    // MARK: - Phases

    @ViewBuilder
    private func content(_ theme: Theme) -> some View {
        switch model.pairingPhase {
        case .pairing:
            workingView(theme)
        case .pendingApproval(let nodeName):
            pendingView(theme, nodeName: nodeName)
        case .idle, .failed:
            inputView(theme)
        }
    }

    // MARK: - Steps

    private func inputView(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            Button {
                showingScanner = true
            } label: {
                Label(l10n(MessageKeys.PAIR_SCAN), systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text(l10n(MessageKeys.PAIR_INPUT_HINT))
                .font(Theme.body)
                .foregroundStyle(theme.textPrimary)
            if let nodeName = model.invitation?.nodeName {
                Text(nodeName)
                    .font(Theme.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            Button(l10n(MessageKeys.ACTION_CANCEL)) { model.cancelPairingAttempt() }
                .buttonStyle(.bordered)
                .padding(.top, Theme.gapS)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Paired, waiting for the operator: the page says so, offers to ask again,
    /// and going back keeps the wait running behind the home banner.
    private func pendingView(_ theme: Theme, nodeName: String) -> some View {
        VStack(spacing: Theme.gapM) {
            ProgressView()
            Text(l10n(MessageKeys.PAIR_WAITING_APPROVAL))
                .font(Theme.headline)
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(nodeName)
                .font(Theme.body)
                .foregroundStyle(theme.textSecondary)
            Button(l10n(MessageKeys.ACTION_RETRY)) {
                Task { await model.resumeStagedSetups() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, Theme.gapS)
            Button(l10n(MessageKeys.ACTION_BACK)) { model.closePairPresentation() }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
        }
        .padding(Theme.gapM)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Input and confirm in one scrolling column: the scan button, the field
    /// the invitation lives in, the failure line when there is one, and the
    /// confirm card when the invitation parses.
    private func inputView(_ theme: Theme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapM) {
                Button {
                    showingScanner = true
                } label: {
                    Label(l10n(MessageKeys.PAIR_SCAN), systemImage: "qrcode.viewfinder")
                        .font(Theme.body)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                invitationField(theme)

                if case .failed(let failure) = model.pairingPhase {
                    Text(ErrorText.text(for: failure))
                        .font(Theme.body)
                        .foregroundStyle(theme.danger)
                }

                if let invitation = model.invitation {
                    confirmCard(theme, invitation: invitation)
                }
            }
            .padding(Theme.gapM)
            .frame(maxWidth: Theme.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    /// The field the invitation stays in, however it arrived — scanned, pasted,
    /// or opened from a link. An invitation is a long line: the field shows a
    /// few lines of it and scrolls inside itself, like Android's.
    private func invitationField(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            Text(l10n(MessageKeys.PAIR_INPUT_HINT))
                .font(Theme.caption)
                .foregroundStyle(theme.textSecondary)
            TextField(l10n(MessageKeys.PAIR_INPUT_HINT), text: Binding(
                get: { model.addNodeText },
                set: { model.addNodeText = $0; model.parseInvitation($0) }
            ), axis: .vertical)
                .font(Theme.body)
                .lineLimit(2...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textFieldStyle(.roundedBorder)
            if model.invitationError != nil {
                Text(l10n(MessageKeys.PAIR_BAD_INVITATION))
                    .font(Theme.caption)
                    .foregroundStyle(theme.danger)
            }
        }
    }

    /// The card a parsed invitation opens: what is being joined, the name this
    /// device introduces itself with for this connection, and the join button.
    private func confirmCard(_ theme: Theme, invitation: SetupURI.Invitation) -> some View {
        let nameBlank = model.deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: Theme.gapM) {
            Text(l10n(MessageKeys.PAIR_CONFIRM_BODY, invitation.origin, invitation.nodeName))
                .font(Theme.body)
                .foregroundStyle(theme.textPrimary)
            VStack(alignment: .leading, spacing: Theme.gapS) {
                Text(l10n(MessageKeys.PAIR_DEVICE_NAME))
                    .font(Theme.caption)
                    .foregroundStyle(theme.textSecondary)
                TextField(l10n(MessageKeys.PAIR_DEVICE_NAME), text: Binding(
                    get: { model.deviceNameDraft },
                    set: { model.deviceNameDraft = $0 }
                ))
                    .font(Theme.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textFieldStyle(.roundedBorder)
                    .disabled(resumingAttempt)
                Text(l10n(model.deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          ? MessageKeys.PAIR_DEVICE_NAME_REQUIRED : MessageKeys.PAIR_DEVICE_NAME_HINT))
                    .font(Theme.caption)
                    .foregroundStyle(theme.textSecondary)
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
                    .font(Theme.body)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(Theme.gapM)
        .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
