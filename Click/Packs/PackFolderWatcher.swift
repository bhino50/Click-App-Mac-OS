import Foundation
import os

/// Watches a directory for changes using a kqueue-backed `DispatchSource`.
/// Yields `()` events on every detected change; the coordinator debounces
/// by re-running the full pack discovery (which is cheap).
actor PackFolderWatcher {
    private static let log = Logger(subsystem: "brandon.Click", category: "watcher")

    private let url: URL
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var continuation: AsyncStream<Void>.Continuation?
    private var stream: AsyncStream<Void>?

    init(url: URL) {
        self.url = url
    }

    func changes() -> AsyncStream<Void> {
        ensureStream()
    }

    func start() {
        guard source == nil else { return }
        // Ensure the continuation exists *before* we wire the event handler —
        // otherwise the handler captures a nil and silently drops every event
        // until `changes()` is first called.
        ensureStream()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.log.error("watcher open() failed for \(self.url.path, privacy: .public)")
            return
        }
        fileDescriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .global(qos: .utility)
        )
        let continuationRef = continuation
        src.setEventHandler {
            continuationRef?.yield(())
        }
        src.setCancelHandler { [fd] in
            close(fd)
        }
        src.resume()
        source = src
    }

    /// Returns the existing stream, creating it (and its continuation) on
    /// first use so callers never observe a nil stream.
    @discardableResult
    private func ensureStream() -> AsyncStream<Void> {
        if let stream { return stream }
        let (s, c) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.stream = s
        self.continuation = c
        return s
    }

    func stop() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            // cancel handler closes it; defensive guard for double-close.
            fileDescriptor = -1
        }
        continuation?.finish()
        continuation = nil
        stream = nil
    }
}
