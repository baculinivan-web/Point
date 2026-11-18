import CoreServices
import Foundation

/// Downloads installers in the browser process instead of WebKit's sandbox.
/// Marks every completed file as an Internet download for Gatekeeper.
final class InstallerDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let source: URL
    private let progressHandler: @Sendable (Double?) -> Void
    private let completion: @Sendable (Result<Void, any Error>) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var holdsAccess = false

    init(destination: URL, source: URL,
         progress: @escaping @Sendable (Double?) -> Void,
         completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        self.destination = destination
        self.source = source
        self.progressHandler = progress
        self.completion = completion
    }

    func start(request: URLRequest, cookies: [HTTPCookie]) {
        holdsAccess = destination.startAccessingSecurityScopedResource()
        let configuration = URLSessionConfiguration.ephemeral
        for cookie in cookies { configuration.httpCookieStorage?.setCookie(cookie) }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progressHandler(totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                throw URLError(.badServerResponse)
            }
            // moveItem refuses to overwrite an existing user file.
            try FileManager.default.moveItem(at: location, to: destination)
            var url = destination
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
                kLSQuarantineTimeStampKey as String: Date(),
                kLSQuarantineAgentNameKey as String: "Point",
                kLSQuarantineDataURLKey as String: source
            ]
            try url.setResourceValues(values)
            completion(.success(()))
        } catch { completion(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        if let error { completion(.failure(error)) }
        if holdsAccess { destination.stopAccessingSecurityScopedResource() }
        session.finishTasksAndInvalidate()
        self.session = nil
        self.task = nil
    }
}
