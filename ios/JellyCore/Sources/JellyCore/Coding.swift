import Foundation

/// Jellyfin's JSON uses PascalCase keys ("PlaySessionId"); Swift properties use
/// camelCase ("playSessionId"). These coders convert the first letter only.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

public enum JellyfinCoding {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { path in
            let key = path.last!
            if key.intValue != nil { return key }
            return AnyCodingKey(stringValue: lowerFirst(key.stringValue))
        }
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .custom { path in
            let key = path.last!
            if key.intValue != nil { return key }
            return AnyCodingKey(stringValue: upperFirst(key.stringValue))
        }
        return e
    }

    static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }

    static func upperFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
}
