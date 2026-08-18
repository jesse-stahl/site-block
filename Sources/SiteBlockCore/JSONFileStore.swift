import Foundation

/// The one JSON-file persistence policy shared by every store in SiteBlock: pretty, sorted keys,
/// atomic writes, containing directory created on demand, and a caller-supplied default when the
/// file does not exist yet (a missing file is "nothing saved", never an error).
public struct JSONFileStore<Value: Codable> {

    public let url: URL
    private let empty: () -> Value

    public init(url: URL, empty: @escaping () -> Value) {
        self.url = url
        self.empty = empty
    }

    /// Load the persisted value. Returns `empty()` if the file does not exist yet.
    /// Throws only if the file exists but cannot be read or decoded.
    public func load() throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return empty() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    /// Persist the value, creating the containing directory if needed. Written atomically.
    public func save(_ value: Value) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
