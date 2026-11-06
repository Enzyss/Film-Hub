import Foundation

/// Turns what the user typed into the URLs to try, in order.
public enum ServerAddress {
    /// "jelly.example.com" -> [https://jelly.example.com, http://jelly.example.com]
    /// "192.168.1.5:8096"  -> [http://192.168.1.5:8096, https://192.168.1.5:8096]
    /// "https://x.com/jf/" -> [https://x.com/jf]
    public static func candidates(from input: String) -> [URL] {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty, !text.contains(" ") else { return [] }

        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: text), url.host != nil else { return [] }
            return [url]
        }

        // No scheme: a LAN address or explicit port usually means plain http.
        let hostPart = text.split(separator: "/").first.map(String.init) ?? text
        let looksLocal = hostPart.contains(":") || isIPv4(hostPart.split(separator: ":").first.map(String.init) ?? "")
            || hostPart.hasSuffix(".local")
        let schemes = looksLocal ? ["http", "https"] : ["https", "http"]
        return schemes.compactMap { scheme in
            guard let url = URL(string: "\(scheme)://\(text)"), url.host != nil else { return nil }
            return url
        }
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
