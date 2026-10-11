import Foundation

struct InstalledBrowserExtension: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var version: String
    var isEnabled: Bool
    var permissions: [String]
    var sites: [String]
    var chromeWebStoreID: String? = nil
}

/// Resources are copied into Point; grants and identity survive moving the original folder.
struct BrowserExtensionStore {
    let root: URL
    var indexURL: URL { root.appendingPathComponent("extensions.json") }
    func resources(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    func read() throws -> [InstalledBrowserExtension] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let records = try JSONDecoder().decode([InstalledBrowserExtension].self, from: Data(contentsOf: indexURL))
        guard Set(records.map(\.id)).count == records.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return records
    }

    func write(_ records: [InstalledBrowserExtension]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: indexURL, options: .atomic)
    }

    func copyResources(from source: URL, id: UUID) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        let values = try source.resourceValues(forKeys: keys)
        guard values.isDirectory == true, values.isSymbolicLink != true,
              FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path)
        else { throw CocoaError(.fileReadCorruptFile) }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown) }
        for case let url as URL in enumerator {
            let item = try url.resourceValues(forKeys: keys)
            guard item.isSymbolicLink != true,
                  item.isDirectory == true || item.isRegularFile == true
            else { throw CocoaError(.fileReadUnsupportedScheme) }
        }
        if let enumerationError { throw enumerationError }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: resources(for: id))
    }
}
