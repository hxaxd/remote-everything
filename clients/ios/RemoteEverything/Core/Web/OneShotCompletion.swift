import Foundation

/// Owns a callback that must be completed exactly once.
/// WebKit requires every JavaScript dialog completion handler to be resolved,
/// including when its page or WebView disappears while the dialog is visible.
@MainActor
final class OneShotCompletion<Value> {
    private var handler: ((Value) -> Void)?

    init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    var isResolved: Bool { handler == nil }

    @discardableResult
    func resolve(_ value: Value) -> Bool {
        guard let handler else { return false }
        self.handler = nil
        handler(value)
        return true
    }
}
