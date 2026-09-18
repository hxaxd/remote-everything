import Foundation

/// Strict parser for the `remote-everything://setup` invitation URI, mirroring
/// contracts/schemas/setup-uri.schema.json: exactly the known parameters, each
/// exactly once, each shaped as the schema says. An invitation that does not
/// parse cleanly is not an invitation.
///
/// Percent-decoding is hand-rolled on purpose. `URLComponents` decodes while it
/// parses and silently merges repeated parameters, which is the wrong behaviour
/// for a security boundary: a duplicate `node` must be refused, not last-one-wins.
enum SetupURI {

    /// One invitation, as a client reads it.
    struct Invitation: Equatable {
        var node: String
        var nodeName: String
        var origin: String
        var invitation: String
        var serverPin: ServerPin?
    }

    /// Why an invitation was refused. The reason is for logs and tests; the UI
    /// says one thing for every malformed invitation.
    enum Rejected: Error, Equatable {
        case notASetupURI
        case malformedParameter
        case unknownParameter(String)
        case duplicateParameter(String)
        case missingParameter(String)
        case badNodeID
        case badNodeName
        case badOrigin
        case badInvitation
        case badPins
        case badEncoding
    }

    private static let knownParameters: Set<String> = [
        "node", "node_name", "origin", "invitation", "fingerprint", "public_key_pin",
    ]

    private static let requiredParameters = ["node", "node_name", "origin", "invitation"]

    static func parse(_ text: String) throws -> Invitation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "remote-everything://setup"
        guard trimmed.hasPrefix(prefix) else { throw Rejected.notASetupURI }
        let rest = String(trimmed.dropFirst(prefix.count))
        // The host is `setup` and nothing else: a path, a second slash or a
        // fragment is a shape this URI does not have.
        guard rest.hasPrefix("?") else { throw Rejected.notASetupURI }
        let query = String(rest.dropFirst())

        var parameters: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pairText = String(pair)
            guard let separator = pairText.firstIndex(of: "=") else { throw Rejected.malformedParameter }
            let key = String(pairText[pairText.startIndex..<separator])
            guard !key.isEmpty else { throw Rejected.malformedParameter }
            guard knownParameters.contains(key) else { throw Rejected.unknownParameter(key) }
            guard parameters[key] == nil else { throw Rejected.duplicateParameter(key) }
            let rawValue = String(pairText[pairText.index(after: separator)...])
            parameters[key] = try percentDecode(rawValue)
        }

        for required in requiredParameters where parameters[required] == nil {
            throw Rejected.missingParameter(required)
        }

        guard let node = parameters["node"], isHex64(node) else { throw Rejected.badNodeID }
        guard let nodeName = parameters["node_name"], isValidNodeName(nodeName) else { throw Rejected.badNodeName }
        guard let origin = parameters["origin"], isOrigin(origin) else { throw Rejected.badOrigin }
        guard let invitation = parameters["invitation"], isInvitationToken(invitation) else {
            throw Rejected.badInvitation
        }

        // Both halves of a self-signed gateway's pin travel together or not at
        // all: a client told to expect a certificate it cannot check is worse
        // off than one told to trust the system.
        let fingerprint = parameters["fingerprint"]
        let publicKeyPin = parameters["public_key_pin"]
        guard (fingerprint == nil) == (publicKeyPin == nil) else { throw Rejected.badPins }
        var pin: ServerPin?
        if let fingerprint, let publicKeyPin {
            guard isHex64(fingerprint), isBase64SHA256(publicKeyPin) else { throw Rejected.badPins }
            pin = ServerPin(certFingerprint: fingerprint, publicKeyPin: publicKeyPin)
        }

        return Invitation(
            node: node,
            nodeName: nodeName,
            origin: origin,
            invitation: invitation,
            serverPin: pin
        )
    }

    // MARK: - Shapes (setup-uri.schema.json)

    static func isHex64(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.allSatisfy { character in
            (character >= "0" && character <= "9") || (character >= "a" && character <= "f")
        }
    }

    /// 1–80 Unicode code points, no C0 or DEL control characters, and not
    /// padded with whitespace. Code points, not grapheme clusters: Go counts
    /// runes and the three clients have to agree on the count.
    static func isValidNodeName(_ value: String) -> Bool {
        guard !value.isEmpty, value.unicodeScalars.count <= 80 else { return false }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    /// `https://host[:port]` — scheme, host, optional port; no path, query or
    /// fragment, and no credentials in the authority.
    static func isOrigin(_ value: String) -> Bool {
        let prefix = "https://"
        guard value.hasPrefix(prefix) else { return false }
        let authority = String(value.dropFirst(prefix.count))
        guard !authority.isEmpty else { return false }
        guard !authority.contains("/"), !authority.contains("?"), !authority.contains("#") else { return false }
        guard !authority.contains("@") else { return false }
        let host: Substring
        let port: Substring?
        if let colon = authority.lastIndex(of: ":") {
            host = authority[authority.startIndex..<colon]
            port = authority[authority.index(after: colon)...]
        } else {
            host = authority[...]
            port = nil
        }
        guard !host.isEmpty else { return false }
        if let port {
            guard !port.isEmpty, port.allSatisfy({ $0.isNumber }) else { return false }
            guard let number = Int(port), (1...65535).contains(number) else { return false }
        }
        return true
    }

    /// Base64url of 32 bytes: exactly 43 characters of the URL-safe alphabet.
    static func isInvitationToken(_ value: String) -> Bool {
        guard value.count == 43 else { return false }
        return value.allSatisfy { character in
            (character >= "A" && character <= "Z")
                || (character >= "a" && character <= "z")
                || (character >= "0" && character <= "9")
                || character == "-"
                || character == "_"
        }
    }

    /// Standard base64 of a 32-byte digest: 43 characters plus one `=`.
    static func isBase64SHA256(_ value: String) -> Bool {
        guard value.count == 44, value.hasSuffix("=") else { return false }
        return value.dropLast().allSatisfy { character in
            (character >= "A" && character <= "Z")
                || (character >= "a" && character <= "z")
                || (character >= "0" && character <= "9")
                || character == "+"
                || character == "/"
        }
    }

    // MARK: - Percent decoding

    /// Form decoding: `%XX` is a byte, `+` is a space, everything else passes
    /// through. Bytes are collected first and decoded as UTF-8 once, so a
    /// multi-byte escape survives.
    static func percentDecode(_ value: String) throws -> String {
        let input = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == 0x25 { // %
                guard index + 2 < input.count,
                      let high = hexValue(input[index + 1]),
                      let low = hexValue(input[index + 2])
                else { throw Rejected.badEncoding }
                output.append((high << 4) | low)
                index += 3
            } else if byte == 0x2B { // +
                output.append(0x20)
                index += 1
            } else {
                output.append(byte)
                index += 1
            }
        }
        guard let decoded = String(bytes: output, encoding: .utf8) else { throw Rejected.badEncoding }
        return decoded
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30 // 0-9
        case 0x41...0x46: return byte - 0x41 + 10 // A-F
        case 0x61...0x66: return byte - 0x61 + 10 // a-f
        default: return nil
        }
    }
}
