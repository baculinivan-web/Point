import Darwin
import Foundation

private let bundleID = "dev.browser.mvp"

private func candidateSockets() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    if let override = ProcessInfo.processInfo.environment["POINT_MCP_SOCKET"],
       override.hasPrefix("/") {
        return [URL(fileURLWithPath: override)]
    }
    return [
        home.appending(path: "Library/Containers/\(bundleID)/Data/Library/Application Support/Point/agent.sock"),
        home.appending(path: "Library/Application Support/Point/agent.sock")
    ]
}

private func connectSocket(at url: URL) -> Int32? {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var noSignal: Int32 = 1
    setsockopt(
        fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
        socklen_t(MemoryLayout.size(ofValue: noSignal))
    )
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(url.path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        Darwin.close(fd)
        return nil
    }
    withUnsafeMutablePointer(to: &address.sun_path) { destination in
        bytes.withUnsafeBytes { source in
            _ = memcpy(destination, source.baseAddress!, source.count)
        }
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        Darwin.close(fd)
        return nil
    }
    return fd
}

private func findConnection() -> Int32? {
    for url in candidateSockets() {
        if let fd = connectSocket(at: url) { return fd }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-b", bundleID]
    try? process.run()
    process.waitUntilExit()
    for _ in 0..<50 {
        usleep(100_000)
        for url in candidateSockets() {
            if let fd = connectSocket(at: url) { return fd }
        }
    }
    return nil
}

guard let socketFD = findConnection() else {
    FileHandle.standardError.write(Data("Point Browser MCP is disabled or Point could not be opened. Enable it in Settings → AI Agents.\n".utf8))
    exit(1)
}

private func reconnectSocket() -> Int32? {
    for url in candidateSockets() {
        if let fd = connectSocket(at: url) { return fd }
    }
    return nil
}

private func writeAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return true }
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

private func unavailableResponse(for requestData: Data) -> Data? {
    guard let object = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
          let id = object["id"] else { return nil }
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "error": [
            "code": -32001,
            "message": "Point Browser restarted or is closed. Open Point and retry; the MCP connection will recover automatically. Browser control must be requested again after a restart."
        ]
    ]
    guard var data = try? JSONSerialization.data(withJSONObject: response) else { return nil }
    data.append(0x0A)
    return data
}

private func takeLines(from buffer: inout Data) -> [Data] {
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
        let line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)
        if !line.isEmpty { lines.append(line) }
    }
    return lines
}

var activeSocket: Int32? = socketFD
var stdinBuffer = Data()
var socketBuffer = Data()
var lastReconnectAttempt = ContinuousClock.now
let standardInputFD = STDIN_FILENO
let standardOutputFD = STDOUT_FILENO

while true {
    var descriptors = [
        pollfd(fd: standardInputFD, events: Int16(POLLIN), revents: 0),
        pollfd(
            fd: activeSocket ?? -1,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
    ]
    let result = Darwin.poll(&descriptors, nfds_t(descriptors.count), 250)
    if result < 0, errno != EINTR { break }

    if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(standardInputFD, &bytes, bytes.count)
        if count <= 0 { break }
        stdinBuffer.append(contentsOf: bytes.prefix(count))
        for line in takeLines(from: &stdinBuffer) {
            var framed = line
            framed.append(0x0A)
            if let fd = activeSocket, writeAll(framed, to: fd) {
                continue
            }
            if let fd = activeSocket { Darwin.close(fd) }
            activeSocket = nil
            socketBuffer.removeAll(keepingCapacity: true)
            if let response = unavailableResponse(for: line) {
                _ = writeAll(response, to: standardOutputFD)
            }
        }
    }

    if let fd = activeSocket,
       descriptors[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count > 0 {
            socketBuffer.append(contentsOf: bytes.prefix(count))
            for line in takeLines(from: &socketBuffer) {
                var framed = line
                framed.append(0x0A)
                guard writeAll(framed, to: standardOutputFD) else { exit(0) }
            }
        } else {
            Darwin.close(fd)
            activeSocket = nil
            socketBuffer.removeAll(keepingCapacity: true)
            lastReconnectAttempt = .now
        }
    }

    if activeSocket == nil,
       ContinuousClock.now - lastReconnectAttempt >= .milliseconds(250) {
        activeSocket = reconnectSocket()
        lastReconnectAttempt = .now
    }
}

if let activeSocket { Darwin.close(activeSocket) }
