import Foundation

class DownloadManager: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: ((Double, String) -> Void)?
    private var expectedSize: Int64 = 0
    private var startTime: Date?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600 // 1 hour max
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func download(
        from url: URL,
        expectedSize: Int64,
        progress: @escaping (Double, String) -> Void
    ) async throws -> URL {
        self.expectedSize = expectedSize
        self.progressHandler = progress
        self.startTime = Date()

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()
        }
    }

    func cancel() {
        downloadTask?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move to a stable temp location before the system cleans up
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("FazmInstall-\(UUID().uuidString).zip")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : expectedSize
        guard total > 0 else { return }

        let fraction = Double(totalBytesWritten) / Double(total)
        let speed = formatSpeed(bytesWritten: totalBytesWritten)
        progressHandler?(min(fraction, 1.0), speed)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private func formatSpeed(bytesWritten: Int64) -> String {
        guard let start = startTime else { return "" }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.5 else { return "" }

        let bytesPerSecond = Double(bytesWritten) / elapsed
        let mbPerSecond = bytesPerSecond / 1_000_000

        let remaining: String
        if expectedSize > 0 && bytesPerSecond > 0 {
            let bytesLeft = Double(expectedSize) - Double(bytesWritten)
            let secondsLeft = bytesLeft / bytesPerSecond
            if secondsLeft < 60 {
                remaining = " — \(Int(secondsLeft))s remaining"
            } else {
                remaining = " — \(Int(secondsLeft / 60))m remaining"
            }
        } else {
            remaining = ""
        }

        return String(format: "%.1f MB/s%@", mbPerSecond, remaining)
    }
}
