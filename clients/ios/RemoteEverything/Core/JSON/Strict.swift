import Foundation

/// Strict decoding helpers.
///
/// The rule the schemas and the Go side both state is that a body a client does
/// not understand is rejected, not tolerated: unknown field, missing field and
/// unknown enum value are all failures. Foundation's synthesised decoding
/// ignores unknown fields, so every DTO here asks for the key list and compares
/// it with the contract.
public enum WireStrict {

    /// A coding key for *any* field name, so the container can report keys the
    /// DTO does not declare.
    public struct AnyKey: CodingKey, Hashable {
        public let stringValue: String
        public var intValue: Int? { nil }

        public init(stringValue: String) {
            self.stringValue = stringValue
        }

        public init?(intValue: Int) {
            return nil
        }
    }

    /// Refuses a body with any field outside `allowed`.
    public static func requireOnly(_ decoder: Decoder, _ allowed: Set<String>, _ context: String) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        for key in container.allKeys where !allowed.contains(key.stringValue) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown field \"\(key.stringValue)\" in \(context)"
                )
            )
        }
    }

    /// A string that is exactly the length the contract allows, counted in
    /// Unicode code points (the same unit Go counts runes in).
    public static func codePoints(_ value: String, maximum: Int, allowEmpty: Bool) -> Bool {
        let count = value.unicodeScalars.count
        guard count <= maximum else { return false }
        guard allowEmpty || count > 0 else { return false }
        return true
    }
}
