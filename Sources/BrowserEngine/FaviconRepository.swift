import BrowserCore
import CoreGraphics
import Foundation
import ImageIO

public actor FaviconRepository {
    private let directoryURL: URL
    private let persistsToDisk: Bool
    private let urlSession: URLSession
    private let memoryCache = NSCache<NSString, FaviconImageBox>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    public init(
        directoryURL: URL? = nil,
        persistsToDisk: Bool = true
    ) {
        self.persistsToDisk = persistsToDisk
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            self.directoryURL = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            )[0]
            .appending(path: "Browser/Favicons", directoryHint: .isDirectory)
        }
        if persistsToDisk {
            urlSession = .shared
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            urlSession = URLSession(configuration: configuration)
        }
        memoryCache.countLimit = 128
        memoryCache.totalCostLimit = 16 * 1_024 * 1_024
    }

    public func image(for iconURL: URL, pageURL: URL) async -> CGImage? {
        guard let key = FaviconCacheKey.make(for: pageURL) else { return nil }
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached.image
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let fileURL = directoryURL.appending(path: key, directoryHint: .notDirectory)
        let task = Task<CGImage?, Never> {
            if persistsToDisk,
               let data = try? Data(contentsOf: fileURL),
               let image = Self.decode(data) {
                return image
            }
            guard let (data, response) = try? await urlSession.data(from: iconURL),
                  data.count <= 2 * 1_024 * 1_024,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let image = Self.decode(data)
            else { return nil }

            if persistsToDisk {
                try? FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
                try? data.write(to: fileURL, options: .atomic)
            }
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            memoryCache.setObject(
                FaviconImageBox(image),
                forKey: key as NSString,
                cost: image.width * image.height * 4
            )
        }
        return image
    }

    public func cachedImage(for pageURL: URL) -> CGImage? {
        guard let key = FaviconCacheKey.make(for: pageURL) else { return nil }
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached.image
        }
        guard persistsToDisk else { return nil }
        let fileURL = directoryURL.appending(path: key, directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: fileURL),
              let image = Self.decode(data)
        else { return nil }
        memoryCache.setObject(
            FaviconImageBox(image),
            forKey: key as NSString,
            cost: image.width * image.height * 4
        )
        return image
    }

    public func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    public func clearAllCaches() throws {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        memoryCache.removeAllObjects()
        guard persistsToDisk else { return }
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try FileManager.default.removeItem(at: directoryURL)
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private final class FaviconImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}
