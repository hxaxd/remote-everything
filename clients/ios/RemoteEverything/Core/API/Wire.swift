import Foundation

// The shared vocabulary of strict decoding: the rejection the DTOs throw, the
// value rules the schemas spell as regexes, and the timestamp shape the wire
// carries. They sit beside `Core/JSON/Strict` (the shape rules — unknown field,
// code points) the way Android's `Wire.kt` sits beside its `Strict`: the shape
// of a body and the rules for its values are two layers of the same refusal.

// MARK: - The rejection

/// Why a decoded body was refused. The first string names the field, the
/// second the body it was read from; the UI never shows either — a refusal is
/// a refusal — but tests and logs read them.
enum DTORejection: Error, Equatable {
    case notTrue(String, String)
    case badField(String, String)
}

// MARK: - Value rules

/// `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` — one hostname label: the first
/// label of the host a public gateway serves the application at.
func isApplicationID(_ value: String) -> Bool {
    guard let first = value.first, first.isASCII, first.isLowercase || first.isNumber else { return false }
    guard value.count <= 63 else { return false }
    if value.count > 1 && value.last == "-" { return false }
    return value.dropFirst().allSatisfy { character in
        character.isASCII && (character.isLowercase || character.isNumber || character == "-")
    }
}

/// `^#[0-9A-Fa-f]{6}$`
func isAccentColor(_ value: String) -> Bool {
    guard value.count == 7, value.hasPrefix("#") else { return false }
    return value.dropFirst().allSatisfy { character in
        (character >= "0" && character <= "9")
            || (character >= "a" && character <= "f")
            || (character >= "A" && character <= "F")
    }
}

/// `^\d+\.\d+\.\d+$`
func isVersionName(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return false }
    return parts.allSatisfy { part in !part.isEmpty && part.allSatisfy(\.isNumber) }
}

func hasNoControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F
    }
}

// MARK: - Timestamps

/// Timestamps on the wire are RFC 3339 in UTC with second precision.
enum WireDate {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
