import Foundation
import Security

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FilmHub", isDirectory: true)
    }
    static var account: URL { support.appendingPathComponent("account.json") }
    static var pendingProgress: URL { support.appendingPathComponent("pending-progress.json") }
    static var homeCache: URL { support.appendingPathComponent("home-cache.json") }
}

/// The signed-in account, minus the token (which lives in the Keychain).
struct StoredAccount: Codable, Equatable {
    var serverURL: URL
    var serverId: String?
    var serverName: String
    var userId: String
    var userName: String
}

enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            // Non-critical cache or account file; the app still works this run.
        }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Tiny Keychain wrapper for the access token.
enum Keychain {
    private static let service = "filmhub.token"

    static func save(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Small preferences that do not need to be secret.
enum Prefs {
    private static let d = UserDefaults.standard

    /// One id per install, kept across logouts: Jellyfin ties sessions to it.
    static var deviceId: String {
        if let id = d.string(forKey: "deviceId") { return id }
        let id = UUID().uuidString
        d.set(id, forKey: "deviceId")
        return id
    }

    static var lastServerURL: String? {
        get { d.string(forKey: "lastServerURL") }
        set { d.set(newValue, forKey: "lastServerURL") }
    }

    static var playerPreference: String? {
        get { d.string(forKey: "playerPreference") }
        set { d.set(newValue, forKey: "playerPreference") }
    }

    static var audioPreference: String? {
        get { d.string(forKey: "audioPreference") }
        set { d.set(newValue, forKey: "audioPreference") }
    }

    static var subtitlePreference: String? {
        get { d.string(forKey: "subtitlePreference") }
        set { d.set(newValue, forKey: "subtitlePreference") }
    }

    static var recentSearches: [String] {
        get { d.stringArray(forKey: "recentSearches") ?? [] }
        set { d.set(Array(newValue.prefix(10)), forKey: "recentSearches") }
    }
}

enum CachePaths {
    static func catalog(_ kind: String) -> URL {
        AppPaths.support.appendingPathComponent("catalog-\(kind).json")
    }
}
