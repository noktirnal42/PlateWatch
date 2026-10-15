import CryptoKit
import Foundation

enum Hashing {
    static func sha256Hex(_ string: String) -> String { sha256Hex(Data(string.utf8)) }
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Atomic JSON persistence for the local records stores. Nothing here syncs: records stay on the operator's Mac until a
/// moderated publication path exists (docs/ACCOUNTABILITY-DATA.md).
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    public let url: URL
    private let pretty: Bool
    public init(url: URL, pretty: Bool = true) { self.url = url; self.pretty = pretty }

    public func load(default fallback: Value) -> Value {
        guard let data = try? Data(contentsOf: url) else { return fallback }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Value.self, from: data)) ?? fallback
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
