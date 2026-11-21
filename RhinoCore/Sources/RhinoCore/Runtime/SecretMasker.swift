import Foundation

/// Keeps the secrets a run handled out of everything that is shown or
/// stored: logs, recorded calls, errors, published values, notifications.
///
/// A secret rarely travels as typed. In a query string it is percent-encoded,
/// inside JSON its quotes and backslashes are escaped; each such form is
/// blanked too. Very short secrets are left alone: blanking every "1" would
/// wreck the text.
struct SecretMasker: Sendable {
    static let replacement = "••••••"
    /// Request and response headers whose values are never recorded, whatever they hold.
    static let sensitiveHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key"]

    /// Every form of every secret, longest first so a longer form is not
    /// broken up by a shorter one it contains.
    private var needles: [String] = []

    var isEmpty: Bool { needles.isEmpty }

    mutating func add(_ secret: String) {
        guard secret.count >= 4 else { return }
        var forms: Set<String> = [secret]
        // As `encodeURIComponent` and as URLComponents write it.
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        for allowed in [unreserved, .urlQueryAllowed] {
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: allowed) { forms.insert(encoded) }
        }
        // As it appears inside a JSON string.
        if let data = try? JSONSerialization.data(withJSONObject: [secret]),
           let text = String(data: data, encoding: .utf8), text.count > 4 {
            forms.insert(String(text.dropFirst(2).dropLast(2)))
        }
        forms.insert(Data(secret.utf8).base64EncodedString())
        needles = Set(needles).union(forms).sorted { $0.count > $1.count }
    }

    func mask(_ text: String) -> String {
        guard !needles.isEmpty else { return text }
        var text = text
        for needle in needles {
            text = text.replacing(needle, with: Self.replacement)
        }
        return text
    }

    /// Headers as they may be recorded: secrets blanked, and the values of
    /// headers that exist to carry credentials blanked altogether.
    func mask(headers: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { name, value in
            (name, Self.sensitiveHeaders.contains(name.lowercased()) ? Self.replacement : mask(value))
        })
    }
}
