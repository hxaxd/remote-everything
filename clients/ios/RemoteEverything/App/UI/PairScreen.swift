import SwiftUI

/// S2: the invitation goes in, the node comes out.
///
/// One screen, the way Android's pair screen is one screen: the input field
/// stays where it is, a scanned or pasted invitation stays readable inside it,
/// and the confirm card appears below it. A failure is a line of text under
/// the field, not a screen of its own. Only a pairing in flight and a pairing
/// waiting for its operator fill the page. Success closes the page itself.
///
/// The camera is its own full-screen cover, because a camera that has to fit a
/// page it is not part of is a camera that asks to be cropped.
struct PairScreen: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingScanner = false

    var body: some View {
        let theme = Theme(colorScheme)
        content(theme)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                }
            }
            .fullScreenCover(isPresented: $showingScanner) {
                ScannerScreen { code in
                    showingScanner = false
                    // A scanned invitation is pasted into the field, the way a
                    // typed one sits there: visible, editable, confirmable.
                    model.addNodeText = code
                    model.parseInvitation(code)
                }
                .environmentObject(model)
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

    /// The invitation is on its way: a spinner, the node's name, and a cancel
    /// that goes back to the input with the invitation kept.
    private func workingView(_ theme: Theme) -> some View {
        VStack(spacing: Theme.gapM) {
            ProgressView()
            Text(l10n(MessageKeys.PAIR_WORKING))
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
                .accessibilityIdentifier("pair.invitation")
                .padding(Theme.gapS + 4)
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
                    .padding(Theme.gapS + 4)
                    .background(theme.bg, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                            .strokeBorder(nameBlank ? theme.danger : theme.hairline, lineWidth: Theme.hairlineWidth)
                    )
                Text(nameBlank ? l10n(MessageKeys.PAIR_DEVICE_NAME_REQUIRED) : l10n(MessageKeys.PAIR_DEVICE_NAME_HINT))
                    .font(Theme.caption)
                    .foregroundStyle(nameBlank ? theme.danger : theme.textSecondary)
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
            .disabled(nameBlank)
            .accessibilityIdentifier("pair.join")
        }
        .padding(Theme.gapM)
        .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
    }
}
