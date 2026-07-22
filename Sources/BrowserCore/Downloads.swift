import Foundation

public enum DownloadState: Equatable, Sendable {
    case awaitingDestination
    case downloading
    case finished
    case cancelled
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .awaitingDestination, .downloading:
            true
        case .finished, .cancelled, .failed:
            false
        }
    }
}

public struct DownloadItem: Identifiable, Sendable {
    public let id: UUID
    public let sourceURL: URL?
    public var suggestedFilename: String
    public var destinationURL: URL?
    public var state: DownloadState
    public var fractionCompleted: Double?
    public var resumeData: Data?
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        sourceURL: URL?,
        suggestedFilename: String,
        destinationURL: URL? = nil,
        state: DownloadState = .awaitingDestination,
        fractionCompleted: Double? = nil,
        resumeData: Data? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.suggestedFilename = suggestedFilename
        self.destinationURL = destinationURL
        self.state = state
        self.fractionCompleted = fractionCompleted
        self.resumeData = resumeData
        self.completedAt = completedAt
    }
}

public enum DownloadHistoryState: String, Codable, Sendable {
    case finished
    case cancelled
    case failed
}

public struct DownloadHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let suggestedFilename: String
    public let destinationURL: URL?
    public let state: DownloadHistoryState
    public let completedAt: Date

    public init(
        id: UUID,
        suggestedFilename: String,
        destinationURL: URL?,
        state: DownloadHistoryState,
        completedAt: Date
    ) {
        self.id = id
        self.suggestedFilename = suggestedFilename
        self.destinationURL = destinationURL
        self.state = state
        self.completedAt = completedAt
    }
}

public protocol DownloadHistoryRepository: Sendable {
    func load() async throws -> [DownloadHistoryRecord]
    func save(_ records: [DownloadHistoryRecord]) async throws
}

public enum DownloadFilenameSanitizer {
    public static func sanitize(
        _ suggestedFilename: String,
        fallback: String = "download"
    ) -> String {
        let leaf = (suggestedFilename as NSString).lastPathComponent
        let forbidden = CharacterSet(charactersIn: "/\\:")
            .union(.controlCharacters)
        let scalars = leaf.unicodeScalars.map { scalar -> Character in
            forbidden.contains(scalar) ? "_" : Character(String(scalar))
        }
        var result = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while result.hasPrefix(".") {
            result.removeFirst()
        }
        result = String(result.prefix(180))

        guard !result.isEmpty, result != ".", result != ".." else {
            return fallback
        }
        return result
    }
}

public enum DownloadDestinationResolver {
    public static func availableURL(
        in directory: URL,
        suggestedFilename: String,
        fileExists: (URL) -> Bool
    ) -> URL {
        let filename = DownloadFilenameSanitizer.sanitize(suggestedFilename)
        let original = directory.appending(path: filename, directoryHint: .notDirectory)
        guard fileExists(original) else { return original }

        let path = filename as NSString
        let pathExtension = path.pathExtension
        let stem = path.deletingPathExtension.isEmpty
            ? "download"
            : path.deletingPathExtension
        var suffix = 2
        while true {
            let candidateName = pathExtension.isEmpty
                ? "\(stem) \(suffix)"
                : "\(stem) \(suffix).\(pathExtension)"
            let candidate = directory.appending(
                path: candidateName,
                directoryHint: .notDirectory
            )
            if !fileExists(candidate) {
                return candidate
            }
            suffix += 1
        }
    }
}
