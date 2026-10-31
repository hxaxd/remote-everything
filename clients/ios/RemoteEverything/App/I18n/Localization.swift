import Foundation

/// The app's language, and how a string is found.
///
/// The system's first choice decides what "follow the system" means (Chinese if
/// it is Chinese, English otherwise), and a choice made in S5 is applied to the
/// bundle immediately — not on the next launch. The lookup itself goes through
/// this one function so a screen never finds a string some other way.
enum Localization {

    private(set) static var bundle: Bundle = .main

    static func apply(_ language: Language) {
        let code = language.resolved == .zh ? "zh-Hans" : "en"
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let localised = Bundle(path: path) {
            bundle = localised
        } else {
            bundle = .main
        }
    }

    /// Records the choice where the system finds it on the next launch as well.
    static func persistPreferredLanguage(_ language: Language) {
        switch language {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .zh:
            UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        case .en:
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
    }
}

/// Looks up one semantic key in the current language.
func l10n(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: Localization.bundle, value: key, comment: "")
}

/// Looks up a key that carries format specifiers ("%1$s", "%1$d").
func l10n(_ key: String, _ first: CVarArg, _ rest: CVarArg...) -> String {
    String(format: l10n(key), arguments: [first] + rest)
}

/// The code → copy mapping of ui-contract §3, spelled by `MessageKeys`: the
/// code decides which name is said, and the catalog decides how this client
/// says it. The prose the gateway sends is never read.
enum ErrorText {

    static func text(for code: ErrorCode) -> String {
        l10n(MessageKeys.forError(code))
    }

    static func key(for code: ErrorCode) -> String {
        MessageKeys.forError(code)
    }

    /// The network layer has no code: it is not a refusal, it is an absence.
    static var network: String { l10n(MessageKeys.ERROR_NETWORK) }

    static func text(for failure: PairingFailure) -> String {
        switch failure {
        case .refusal(let error): return text(for: error.code)
        case .network: return l10n(MessageKeys.PAIR_NETWORK)
        case .client: return l10n(MessageKeys.ERROR_CLIENT)
        }
    }
}

/// The light notices of ui-contract §3.
enum NoticeText {
    static func text(for notice: Notice) -> String {
        switch notice {
        case .busy: return l10n(MessageKeys.ERROR_BUSY)
        case .appGone: return l10n(MessageKeys.ERROR_APP_GONE)
        case .stopFailed: return l10n(MessageKeys.ERROR_STOP_FAILED)
        case .controlFailed: return l10n(MessageKeys.ERROR_CONTROL_FAILED)
        case .network: return ErrorText.network
        case .nodeGone: return l10n(MessageKeys.ERROR_NODE_GONE)
        case .invitationExpired: return l10n(MessageKeys.PAIR_EXPIRED)
        case .credentialLost(let origin): return l10n(MessageKeys.ERROR_CREDENTIAL_LOST, origin)
        }
    }

    static func usesErrorColor(_ notice: Notice) -> Bool {
        switch notice {
        case .stopFailed, .credentialLost, .controlFailed:
            return true
        case .busy, .appGone, .network, .nodeGone, .invitationExpired:
            return false
        }
    }
}
