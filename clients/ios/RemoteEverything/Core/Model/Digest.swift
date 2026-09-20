import CryptoKit
import Foundation

/// Hashing helpers shared by the store, the credential vault and the wire
/// client. All digests are SHA-256 and all hex is lowercase, which is how the
/// protocol writes both a certificate fingerprint and a public key pin.
enum Digest {

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func sha256Hex(_ data: Data) -> String {
        hexString(sha256(data))
    }

    static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    static func hexString(_ data: Data) -> String {
        var output = String()
        output.reserveCapacity(data.count * 2)
        for byte in data {
            output.append(hexDigits[Int(byte >> 4)])
            output.append(hexDigits[Int(byte & 0x0F)])
        }
        return output
    }

    static func base64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    private static let hexDigits: [Character] = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
    ]

    /// The name one origin's material is filed under: stable, ASCII, and not the
    /// origin itself — `re-` plus the first 16 bytes of the origin's digest.
    static func originAlias(_ origin: String) -> String {
        "re-" + String(sha256Hex(Data(origin.utf8)).prefix(32))
    }
}
