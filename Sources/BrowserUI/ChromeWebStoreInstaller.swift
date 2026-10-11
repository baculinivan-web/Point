import BrowserCore
import CryptoKit
import Foundation
import Security
import Synchronization
import zlib

/// Downloads original CRX3 resources. No manifest or JavaScript rewriting is performed.
struct ChromeWebStoreInstaller: Sendable {
    enum Failure: String, LocalizedError {
        case invalidLink = "extensions_store_invalid_link"
        case unavailable = "extensions_store_unavailable"
        case invalidPackage = "extensions_store_invalid_package"
        case tooLarge = "extensions_store_too_large"
        case alreadyInstalled = "extensions_store_already_installed"
        var errorDescription: String? { BrowserLocalization.string(rawValue) }
    }

    static let maximumPackageSize = 128 * 1024 * 1024

    static func extensionID(from input: String) throws -> String {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        func validID(_ value: String) -> Bool {
            value.utf8.count == 32 && value.utf8.allSatisfy { (97...112).contains($0) }
        }
        if validID(input) { return input }
        guard let url = URLComponents(string: input), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host else { throw Failure.invalidLink }
        let parts = url.path.split(separator: "/").map(String.init)
        let prefix = host == "chromewebstore.google.com" ? ["detail"] :
            host == "chrome.google.com" ? ["webstore", "detail"] : []
        guard !prefix.isEmpty, parts.starts(with: prefix),
              parts.count == prefix.count + 1 || parts.count == prefix.count + 2,
              let id = parts.last, validID(id) else { throw Failure.invalidLink }
        return id
    }

    static func downloadURL(for id: String) throws -> URL {
        guard try extensionID(from: id) == id else { throw Failure.invalidLink }
        var url = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        url.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "140.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc")
        ]
        return url.url!
    }

    func download(id: String) async throws -> Data {
        var request = URLRequest(url: try Self.downloadURL(for: id))
        request.timeoutInterval = 120
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 180
        let policy = DownloadPolicy()
        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // Download to disk, keeping large network responses out of memory.
        let file: URL
        let response: URLResponse
        do { (file, response) = try await session.download(for: request) }
        catch {
            if policy.exceededLimit.withLock({ $0 }) { throw Failure.tooLarge }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https" else { throw Failure.unavailable }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumPackageSize else { throw Failure.tooLarge }
        return try Data(contentsOf: file, options: .mappedIfSafe)
    }

    private final class DownloadPolicy: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let exceededLimit = Mutex(false)
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > maximumPackageSize || totalBytesExpectedToWrite > maximumPackageSize {
                exceededLimit.withLock { $0 = true }
                downloadTask.cancel()
            }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            let host = request.url?.host ?? ""
            let allowed = ["google.com", "googleusercontent.com", "gvt1.com"].contains {
                host == $0 || host.hasSuffix("." + $0)
            }
            completionHandler(request.url?.scheme == "https" && allowed ? request : nil)
        }
    }

    /// Verifies the developer proof against the requested store ID and the complete archive.
    /// Format: Chromium components/crx_file/crx3.proto and crx_verifier.cc.
    static func verifiedArchive(_ package: Data, expectedID: String) throws -> Data {
        guard package.count <= maximumPackageSize else { throw Failure.tooLarge }
        guard try package.bytes(0, 4) == Data("Cr24".utf8), try package.uint32(4) == 3 else {
            throw Failure.invalidPackage
        }
        let headerSize = try package.uint32(8)
        guard headerSize <= 4 * 1024 * 1024 else { throw Failure.invalidPackage }
        let fields = try protobuf(package.bytes(12, headerSize))
        guard let signed = fields[10000], signed.count == 1,
              let signedHeader = signed.first,
              let ids = try protobuf(signedHeader)[1], ids.count == 1,
              let declaredID = ids.first, declaredID.count == 16,
              encodedID(declaredID) == expectedID else { throw Failure.invalidPackage }
        let archive = try package.bytes(12 + headerSize, package.count - 12 - headerSize)
        var message = Data("CRX3 SignedData\0".utf8)
        var length = UInt32(signedHeader.count).littleEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(signedHeader)
        message.append(archive)
        var developerProof = false
        for field in [2, 3] {
            for proof in fields[field] ?? [] {
                let parts = try protobuf(proof)
                guard let keys = parts[1], keys.count == 1, let publicKey = keys.first,
                      let signatures = parts[2], signatures.count == 1, let signature = signatures.first
                else { throw Failure.invalidPackage }
                let keyData = try subjectPublicKey(publicKey)
                let attributes: [CFString: Any] = [
                    kSecAttrKeyType: field == 2 ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
                    kSecAttrKeyClass: kSecAttrKeyClassPublic
                ]
                guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil),
                      SecKeyVerifySignature(key, field == 2 ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256,
                                            message as CFData, signature as CFData, nil)
                else { throw Failure.invalidPackage }
                if Data(SHA256.hash(data: publicKey).prefix(16)) == declaredID { developerProof = true }
            }
        }
        guard developerProof else { throw Failure.invalidPackage }
        return archive
    }

    static func encodedID(_ bytes: Data) -> String {
        String(bytes: bytes.flatMap { [97 + ($0 >> 4), 97 + ($0 & 15)] }, encoding: .utf8)!
    }

    private static func protobuf(_ data: Data) throws -> [Int: [Data]] {
        var offset = 0
        func varint() throws -> Int {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                let byte = try data.bytes(offset, 1)[0]
                offset += 1
                guard shift < 63 || byte <= 1 else { throw Failure.invalidPackage }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 {
                    guard value <= UInt64(Int.max) else { throw Failure.invalidPackage }
                    return Int(value)
                }
            }
            throw Failure.invalidPackage
        }
        var result: [Int: [Data]] = [:]
        while offset < data.count {
            let tag = try varint()
            guard tag >> 3 > 0 else { throw Failure.invalidPackage }
            switch tag & 7 {
            case 0: _ = try varint()
            case 1: _ = try data.bytes(offset, 8); offset += 8
            case 2:
                let size = try varint()
                result[tag >> 3, default: []].append(try data.bytes(offset, size))
                offset += size
            case 5: _ = try data.bytes(offset, 4); offset += 4
            default: throw Failure.invalidPackage
            }
        }
        return result
    }

    private static func subjectPublicKey(_ spki: Data) throws -> Data {
        var offset = 0
        func element(_ tag: UInt8) throws -> Data {
            guard try spki.bytes(offset, 1)[0] == tag else { throw Failure.invalidPackage }
            offset += 1
            let first = try spki.bytes(offset, 1)[0]; offset += 1
            var size = Int(first)
            if first & 128 != 0 {
                let count = Int(first & 127)
                guard (1...4).contains(count) else { throw Failure.invalidPackage }
                size = 0
                for byte in try spki.bytes(offset, count) { size = size * 256 + Int(byte) }
                offset += count
            }
            let contents = try spki.bytes(offset, size)
            offset += size
            return contents
        }
        let sequence = try element(0x30)
        guard offset == spki.count else { throw Failure.invalidPackage }
        // Parse again against the inner sequence, keeping the DER lengths bounded.
        return try publicKeyBits(sequence)
    }

    private static func publicKeyBits(_ sequence: Data) throws -> Data {
        var offset = 0
        func next(_ expected: UInt8) throws -> Data {
            guard try sequence.bytes(offset, 1)[0] == expected else { throw Failure.invalidPackage }
            offset += 1
            let byte = try sequence.bytes(offset, 1)[0]; offset += 1
            var size = Int(byte)
            if byte & 128 != 0 {
                let count = Int(byte & 127)
                guard (1...4).contains(count) else { throw Failure.invalidPackage }
                size = 0
                for part in try sequence.bytes(offset, count) { size = size * 256 + Int(part) }
                offset += count
            }
            let value = try sequence.bytes(offset, size); offset += size
            return value
        }
        _ = try next(0x30)
        let bits = try next(0x03)
        guard offset == sequence.count, bits.first == 0 else { throw Failure.invalidPackage }
        return Data(bits.dropFirst())
    }

    /// ZIP32 only; bounded native extraction avoids subprocesses and archive path traversal.
    static func extract(_ zip: Data, to destination: URL) throws {
        guard zip.count >= 22, zip.count <= maximumPackageSize else { throw Failure.invalidPackage }
        let lower = max(0, zip.count - 22 - 65535)
        guard let end = stride(from: zip.count - 22, through: lower, by: -1).first(where: {
            (try? zip.uint32($0)) == 0x06054b50 &&
                (try? zip.uint16($0 + 20)).map { $0 + 22 } == zip.count - $0
        }) else { throw Failure.invalidPackage }
        guard try zip.uint16(end + 4) == 0, try zip.uint16(end + 6) == 0,
              try zip.uint16(end + 8) == zip.uint16(end + 10) else { throw Failure.invalidPackage }
        let count = try zip.uint16(end + 10)
        let centralSize = try zip.uint32(end + 12)
        let centralOffset = try zip.uint32(end + 16)
        guard count > 0, count <= 30000, centralOffset + centralSize == end else { throw Failure.invalidPackage }
        struct Entry {
            let name: String
            let offset: Int
            let compressed: Int
            let expanded: Int
            let method: Int
            let crc: Int
            let directory: Bool
        }
        var entries: [Entry] = [], names: Set<String> = [], total = 0, cursor = centralOffset
        for _ in 0..<count {
            guard try zip.uint32(cursor) == 0x02014b50 else { throw Failure.invalidPackage }
            let flags = try zip.uint16(cursor + 8), method = try zip.uint16(cursor + 10)
            let compressed = try zip.uint32(cursor + 20), expanded = try zip.uint32(cursor + 24)
            let nameSize = try zip.uint16(cursor + 28), extraSize = try zip.uint16(cursor + 30)
            let commentSize = try zip.uint16(cursor + 32), local = try zip.uint32(cursor + 42)
            let mode = try zip.uint32(cursor + 38) >> 16 & 0xf000
            let rawName = try zip.bytes(cursor + 46, nameSize)
            guard let name = String(data: rawName, encoding: .utf8), !name.isEmpty,
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0"),
                  !name.split(separator: "/", omittingEmptySubsequences: false).dropLast(name.hasSuffix("/") ? 1 : 0)
                    .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  names.insert(name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  mode == 0 || mode == 0x8000 || mode == 0x4000,
                  flags & ~0x080e == 0, flags & 1 == 0, method == 0 || method == 8,
                  try zip.uint16(cursor + 34) == 0,
                  try zip.uint32(local) == 0x04034b50,
                  try zip.uint16(local + 6) == flags, try zip.uint16(local + 8) == method,
                  try zip.uint16(local + 26) == nameSize,
                  try zip.bytes(local + 30, nameSize) == rawName else { throw Failure.invalidPackage }
            total += expanded
            guard expanded <= 64 * 1024 * 1024, total <= 512 * 1024 * 1024 else { throw Failure.tooLarge }
            let start = try local + 30 + nameSize + zip.uint16(local + 28)
            guard local < centralOffset, start + compressed <= centralOffset else { throw Failure.invalidPackage }
            if flags & 8 == 0 {
                guard try zip.uint32(local + 14) == zip.uint32(cursor + 16),
                      try zip.uint32(local + 18) == compressed, try zip.uint32(local + 22) == expanded
                else { throw Failure.invalidPackage }
            }
            let directory = name.hasSuffix("/")
            guard !directory || expanded == 0 else { throw Failure.invalidPackage }
            entries.append(Entry(name: name, offset: start, compressed: compressed, expanded: expanded,
                                 method: method, crc: try zip.uint32(cursor + 16), directory: directory))
            cursor += 46 + nameSize + extraSize + commentSize
            guard cursor <= end else { throw Failure.invalidPackage }
        }
        guard cursor == end, entries.contains(where: { $0.name == "manifest.json" && !$0.directory })
        else { throw Failure.invalidPackage }
        // The destination must be new and owned by this operation; never follow pre-existing links.
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.invalidPackage }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            for entry in entries {
                let file = destination.appendingPathComponent(entry.name)
                if entry.directory {
                    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
                    continue
                }
                let compressed = try zip.bytes(entry.offset, entry.compressed)
                let output: Data
                if entry.method == 0 {
                    guard entry.compressed == entry.expanded else { throw Failure.invalidPackage }
                    output = compressed
                } else {
                    var stream = z_stream()
                    guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
                    else { throw Failure.invalidPackage }
                    defer { inflateEnd(&stream) }
                    var inflated = Data(count: max(1, entry.expanded))
                    let status = compressed.withUnsafeBytes { input in
                        inflated.withUnsafeMutableBytes { buffer in
                            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                            stream.avail_in = uInt(input.count)
                            stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                            stream.avail_out = uInt(buffer.count)
                            return inflate(&stream, Z_FINISH)
                        }
                    }
                    guard status == Z_STREAM_END, stream.total_out == entry.expanded,
                          stream.total_in == entry.compressed else { throw Failure.invalidPackage }
                    inflated.count = entry.expanded
                    output = inflated
                }
                let checksum = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                guard checksum == entry.crc else { throw Failure.invalidPackage }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try output.write(to: file, options: .withoutOverwriting)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

private extension Data {
    func bytes(_ offset: Int, _ count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= self.count, count <= self.count - offset else {
            throw ChromeWebStoreInstaller.Failure.invalidPackage
        }
        return subdata(in: offset..<(offset + count))
    }
    func uint16(_ offset: Int) throws -> Int {
        let value = try bytes(offset, 2)
        return Int(value[0]) | Int(value[1]) << 8
    }
    func uint32(_ offset: Int) throws -> Int {
        let value = try bytes(offset, 4)
        return Int(value[0]) | Int(value[1]) << 8 | Int(value[2]) << 16 | Int(value[3]) << 24
    }
}
