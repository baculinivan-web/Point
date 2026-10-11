import CryptoKit
import Foundation
import Security
import Testing
import WebKit
import zlib
@testable import BrowserUI

@Suite("Chrome Web Store installer")
struct ChromeWebStoreInstallerTests {
    private let vimiumID = "dbepggeogbaibhgnhhndojpepiihcmeb"

    @Test func acceptsModernLegacyAndRawIDs() throws {
        for value in [vimiumID, "https://chromewebstore.google.com/detail/vimium/\(vimiumID)?hl=ru",
                      "https://chromewebstore.google.com/detail/\(vimiumID)",
                      "https://chrome.google.com/webstore/detail/vimium/\(vimiumID)"] {
            #expect(try ChromeWebStoreInstaller.extensionID(from: " \(value)\n") == vimiumID)
        }
        let url = try ChromeWebStoreInstaller.downloadURL(for: vimiumID)
        #expect(url.host == "clients2.google.com")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "x" })?.value == "id=\(vimiumID)&uc")
    }

    @Test func rejectsForeignURLsAndMalformedIDs() {
        for value in ["https://example.com/detail/\(vimiumID)", "http://chromewebstore.google.com/detail/\(vimiumID)",
                      "https://chromewebstore.google.com.evil.test/detail/\(vimiumID)",
                      "https://user@chromewebstore.google.com/detail/\(vimiumID)",
                      "https://chromewebstore.google.com:443/detail/\(vimiumID)",
                      "https://chromewebstore.google.com/category/\(vimiumID)",
                      "https://chromewebstore.google.com/detail/a/b/\(vimiumID)",
                      String(repeating: "q", count: 32), "", String(vimiumID.dropLast())] {
            #expect(throws: ChromeWebStoreInstaller.Failure.self) {
                try ChromeWebStoreInstaller.extensionID(from: value)
            }
        }
    }

    @Test(arguments: [false, true]) func verifiesRSAAndECDSASignaturesAndRejectsTampering(rsa: Bool) throws {
        let archive = zip([("manifest.json", Data("{}".utf8))])
        let signed = try sign(archive, rsa: rsa)
        #expect(try ChromeWebStoreInstaller.verifiedArchive(signed.package, expectedID: signed.id) == archive)
        #expect(throws: ChromeWebStoreInstaller.Failure.self) {
            try ChromeWebStoreInstaller.verifiedArchive(signed.package, expectedID: vimiumID)
        }
        var corrupt = signed.package
        corrupt[corrupt.count - 1] ^= 1
        #expect(throws: ChromeWebStoreInstaller.Failure.self) {
            try ChromeWebStoreInstaller.verifiedArchive(corrupt, expectedID: signed.id)
        }
        for cut in [0, 4, 11, 20, signed.package.count - 1] {
            #expect(throws: ChromeWebStoreInstaller.Failure.self) {
                try ChromeWebStoreInstaller.verifiedArchive(Data(signed.package.prefix(cut)), expectedID: signed.id)
            }
        }
    }

    @Test func extractsOriginalResourcesAndDeflate() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = Data("{\"manifest_version\":3,\"name\":\"Original\",\"version\":\"1.0\"}".utf8)
        let contents = Data("hello hello hello".utf8)
        let compressed = Data([203,72,205,201,201,87,200,64,144,0])
        let archive = zip([("manifest.json", manifest), ("nested/original.js", contents)], deflatedLast: compressed)
        try ChromeWebStoreInstaller.extract(archive, to: root)
        #expect(try Data(contentsOf: root.appendingPathComponent("manifest.json")) == manifest)
        #expect(try Data(contentsOf: root.appendingPathComponent("nested/original.js")) == contents)
    }

    @Test func rejectsTraversalAliasesSymlinksCorruptionAndSizeBombs() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = ("manifest.json", Data("{}".utf8))
        var badArchives = ["../escape", "/absolute", "folder/../../escape", "folder\\escape", "a//b", "./file", "volume:file", "file\0x"].map {
            zip([manifest, ($0, Data("x".utf8))])
        }
        badArchives.append(zip([manifest, ("MANIFEST.JSON", Data("x".utf8))]))
        badArchives.append(zip([manifest, ("link", Data("../escape".utf8))], lastMode: 0xa000))
        badArchives.append(zip([("other.json", Data("{}".utf8))]))
        var corrupt = zip([manifest]); corrupt[30 + "manifest.json".utf8.count] ^= 1
        badArchives.append(corrupt)
        var bomb = zip([manifest]); let central = 30 + "manifest.json".utf8.count + 2
        bomb.replaceSubrange((central + 24)..<(central + 28), with: little(65 * 1024 * 1024, 4))
        badArchives.append(bomb)
        for archive in badArchives {
            #expect(throws: (any Error).self) { try ChromeWebStoreInstaller.extract(archive, to: root) }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }

    @MainActor @Test func storeInstallPreservesResourcesPersistsSourceRejectsDuplicateAndCleansCancelledInstall() async throws {
        let root = temporaryRoot(), deniedRoot = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: deniedRoot)
        }
        let manifest = Data("{\"manifest_version\":3,\"name\":\"Store fixture\",\"version\":\"1.0\",\"permissions\":[\"storage\"]}".utf8)
        let script = Data("// original, unchanged\n".utf8)
        let signed = try sign(zip([("manifest.json", manifest), ("original.js", script)]))
        let manager = BrowserExtensionManager(root: root,
            controller: BrowserExtensionManager.makeController(configuration: .init(identifier: UUID())),
            approvalHandler: { _, _, _ in true })
        await manager.installFromWebStore(signed.id, download: { _ in signed.package })
        #expect(manager.errorMessage == nil)
        #expect(manager.storeInstallationStage == .installed)
        #expect(manager.storeInstallationID == signed.id)
        let record = try #require(manager.installed.first)
        #expect(record.chromeWebStoreID == signed.id)
        let store = BrowserExtensionStore(root: root)
        #expect(try store.read() == manager.installed)
        #expect(try Data(contentsOf: store.resources(for: record.id).appendingPathComponent("manifest.json")) == manifest)
        #expect(try Data(contentsOf: store.resources(for: record.id).appendingPathComponent("original.js")) == script)
        await manager.installFromWebStore(signed.id, download: { _ in
            Issue.record("A duplicate must not be downloaded"); return Data()
        })
        #expect(manager.installed.count == 1)
        #expect(manager.errorMessage != nil)
        #expect(manager.storeInstallationStage == nil)
        let denied = BrowserExtensionManager(root: deniedRoot,
            controller: BrowserExtensionManager.makeController(configuration: .init(identifier: UUID())),
            approvalHandler: { _, _, _ in false })
        await denied.installFromWebStore(signed.id, download: { _ in signed.package })
        #expect(denied.installed.isEmpty)
        #expect(denied.errorMessage == nil)
        #expect(denied.storeInstallationStage == .cancelled)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: deniedRoot.path))?.isEmpty == true)
        await manager.setEnabled(false, id: record.id)
    }

    @Test func oldInstallationMetadataStillDecodes() throws {
        let old = Data("[{\"id\":\"\(UUID().uuidString)\",\"name\":\"Old\",\"version\":\"1\",\"isEnabled\":true,\"permissions\":[],\"sites\":[]}]".utf8)
        #expect(try JSONDecoder().decode([InstalledBrowserExtension].self, from: old).first?.chromeWebStoreID == nil)
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    private func little(_ value: Int, _ size: Int) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func zip(_ files: [(String, Data)], deflatedLast: Data? = nil, lastMode: Int = 0x8000) -> Data {
        var output = Data(), central = Data()
        for (index, file) in files.enumerated() {
            let (name, contents) = file, rawName = Data(name.utf8), offset = output.count
            let compressed = index == files.count - 1 ? deflatedLast ?? contents : contents
            let method = index == files.count - 1 && deflatedLast != nil ? 8 : 0
            let crc = contents.withUnsafeBytes { Int(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            for (value, size) in [(0x04034b50,4),(20,2),(0x800,2),(method,2),(0,2),(0,2),(crc,4),(compressed.count,4),(contents.count,4),(rawName.count,2),(0,2)] {
                output.append(little(value,size))
            }
            output.append(rawName); output.append(compressed)
            for (value,size) in [(0x02014b50,4),(0x314,2),(20,2),(0x800,2),(method,2),(0,2),(0,2),(crc,4),(compressed.count,4),(contents.count,4),(rawName.count,2),(0,2),(0,2),(0,2),(0,2),((index == files.count - 1 ? lastMode : 0x8000) << 16,4),(offset,4)] {
                central.append(little(value,size))
            }
            central.append(rawName)
        }
        let centralOffset = output.count
        output.append(central)
        for (value,size) in [(0x06054b50,4),(0,2),(0,2),(files.count,2),(files.count,2),(central.count,4),(centralOffset,4),(0,2)] {
            output.append(little(value,size))
        }
        return output
    }

    private func proto(_ field: Int, _ data: Data) -> Data {
        func varint(_ value: Int) -> Data {
            var value = value, result = Data()
            while value >= 128 { result.append(UInt8(value & 127) | 128); value >>= 7 }
            result.append(UInt8(value)); return result
        }
        return varint(field << 3 | 2) + varint(data.count) + data
    }

    private func der(_ tag: UInt8, _ contents: Data) -> Data {
        let size = contents.count
        let length = size < 128 ? Data([UInt8(size)]) : size < 256 ? Data([0x81,UInt8(size)]) : Data([0x82,UInt8(size >> 8),UInt8(size & 255)])
        return Data([tag]) + length + contents
    }

    private func sign(_ archive: Data, rsa: Bool = false) throws -> (package: Data, id: String) {
        let key = try #require(SecKeyCreateRandomKey([
            kSecAttrKeyType: rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: rsa ? 2048 : 256
        ] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let raw = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let algorithm = rsa ? Data([0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00]) :
            Data([0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07])
        let spki = der(0x30, algorithm + der(0x03, Data([0]) + raw))
        let idBytes = Data(SHA256.hash(data: spki).prefix(16))
        let signedHeader = proto(1, idBytes)
        let message = Data("CRX3 SignedData\0".utf8) + little(signedHeader.count,4) + signedHeader + archive
        let signature = try #require(SecKeyCreateSignature(key, rsa ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256, message as CFData, nil)) as Data
        let header = proto(rsa ? 2 : 3, proto(1, spki) + proto(2, signature)) + proto(10000, signedHeader)
        return (Data("Cr24".utf8) + little(3,4) + little(header.count,4) + header + archive,
                ChromeWebStoreInstaller.encodedID(idBytes))
    }
}
