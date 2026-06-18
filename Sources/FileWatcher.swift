import Foundation
import CoreServices

// Watches ~/.claude/projects/ recursively via FSEvents.
// Fires debounced callback within ~0.5s of any .jsonl write.
final class FileWatcher {
    private var streamRef: FSEventStreamRef?
    private var debounceTimer: DispatchWorkItem?
    private let debounceDelay: TimeInterval = 0.8
    private let callback: () -> Void

    init(path: String, callback: @escaping () -> Void) {
        self.callback = callback
        start(path: path)
    }

    private func start(path: String) {
        let paths = [path] as CFArray
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )

        streamRef = FSEventStreamCreate(
            nil,
            { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
                guard let info = clientInfo else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()

                // Only react to .jsonl changes
                // kFSEventStreamCreateFlagUseCFTypes delivers a CFArray via raw pointer
                let pathsNS = Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue()
                guard let paths = pathsNS as? [String],
                      paths.contains(where: { $0.hasSuffix(".jsonl") }) else { return }

                watcher.scheduleDebounced()
            },
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,  // coalescing latency (seconds)
            flags
        )

        guard let stream = streamRef else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func scheduleDebounced() {
        debounceTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.callback()
        }
        debounceTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: item)
    }

    deinit {
        debounceTimer?.cancel()
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
