import CoreServices
import Foundation

/// Watches one or more filesystem paths and emits typed observations
/// for every change. Wraps the C-level FSEvents API.
///
/// Callers receive `FSEventsObservation` values via the `handler`
/// closure. The watcher batches events with a 500ms latency window
/// — bulk operations like a Finder folder move trigger one callback
/// per ~half-second rather than one per file, which keeps the
/// downstream OperationEngine queue manageable.
///
/// Lifecycle: construct with paths + handler, call `start()`, keep
/// the instance alive while you want events, call `stop()` (or let
/// deinit handle it) when done. The watcher is not reusable after
/// stop() — construct a new instance to resume watching.
///
/// SP-1 v1 captures path + event-type flags. Extended data (file ID
/// + inode) lands in a follow-up when cross-volume move detection
/// needs it.
public final class FSEventsWatcher {
    public typealias Handler = @Sendable (FilesystemEventBatch) -> Void

    /// Time window in seconds for the kernel to coalesce events
    /// before delivering them to our callback. Higher values smooth
    /// bursty filesystem activity at the cost of perceived latency.
    public static let defaultEventCoalescingLatency: CFTimeInterval = 0.5

    /// Sentinel value meaning "start the stream from now; ignore
    /// historical events." Equivalent to FSEvents' built-in constant
    /// but with a Swift-friendly name and type.
    public static let sinceNow: FSEventStreamEventId =
        .init(kFSEventStreamEventIdSinceNow)

    private let watchedPaths: [String]
    private let handler: Handler
    private let sinceWhen: FSEventStreamEventId
    private let dispatchQueue: DispatchQueue
    private let coalescingLatency: CFTimeInterval
    private var stream: FSEventStreamRef?

    public init(
        watchedPaths: [String],
        sinceWhen: FSEventStreamEventId = FSEventsWatcher.sinceNow,
        coalescingLatency: CFTimeInterval = FSEventsWatcher.defaultEventCoalescingLatency,
        handler: @escaping Handler
    ) {
        self.watchedPaths = watchedPaths
        self.sinceWhen = sinceWhen
        self.coalescingLatency = coalescingLatency
        self.handler = handler
        dispatchQueue = DispatchQueue(
            label: "com.crateagent.fsevents",
            qos: .utility
        )
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    public func start() {
        guard stream == nil else { return }

        let context = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
        defer { context.deallocate() }
        context.initialize(to: FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        ))

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
        )

        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            FSEventsWatcher.callbackTrampoline,
            context,
            watchedPaths as CFArray,
            sinceWhen,
            coalescingLatency,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(createdStream, dispatchQueue)
        FSEventStreamStart(createdStream)
        stream = createdStream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Static C-callback trampoline. C function pointers cannot
    /// capture state, so the caller installs an opaque pointer to
    /// `self` in the context info; we cast it back here.
    private static let callbackTrampoline: FSEventStreamCallback = {
        _, contextInfo, numberOfEvents, eventPaths, eventFlags, eventIds in
        guard let contextInfo else { return }
        let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
        watcher.dispatchEvents(
            count: numberOfEvents,
            pathsOpaquePointer: eventPaths,
            flags: eventFlags,
            ids: eventIds
        )
    }

    private func dispatchEvents(
        count: Int,
        pathsOpaquePointer: UnsafeRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>,
        ids: UnsafePointer<FSEventStreamEventId>
    ) {
        // With kFSEventStreamCreateFlagUseCFTypes set, eventPaths is
        // a CFArray of CFString.
        let pathsArray = Unmanaged<CFArray>.fromOpaque(pathsOpaquePointer)
            .takeUnretainedValue()

        let flagsBuffer = UnsafeBufferPointer(start: flags, count: count)
        let idsBuffer = UnsafeBufferPointer(start: ids, count: count)

        var observations: [FSEventsObservation] = []
        observations.reserveCapacity(count)
        for index in 0 ..< count {
            guard let pathPointer = CFArrayGetValueAtIndex(pathsArray, index) else {
                continue
            }
            let cfString = Unmanaged<CFString>
                .fromOpaque(pathPointer)
                .takeUnretainedValue()
            let pathString = cfString as String
            observations.append(FSEventsObservation(
                path: pathString,
                rawFlags: flagsBuffer[index], eventID: idsBuffer[index]
            ))
        }

        handler(FilesystemEventBatch(observations: observations, highestEventID: idsBuffer.max() ?? 0))
    }
}

/// One filesystem change observed by an `FSEventsWatcher`. Parses the
/// raw `FSEventStreamEventFlags` bitmask into discrete booleans so
/// callers don't need to know the underlying flag constants.
///
/// Initializer is public so tests can construct observations directly
/// without spinning up a real FSEvent stream.
public struct FSEventsObservation: Sendable, Equatable {
    public let eventID: UInt64?
    public let path: String
    public let isFile: Bool
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let wasCreated: Bool
    public let wasRemoved: Bool
    public let wasRenamed: Bool
    public let wasModified: Bool
    public let requiresReconciliation: Bool
    public let rootChanged: Bool

    public init(path: String, rawFlags: FSEventStreamEventFlags, eventID: UInt64? = nil) {
        self.eventID = eventID
        self.path = path
        let flagsAsInt = Int(rawFlags)
        requiresReconciliation = (flagsAsInt & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)) != 0
        isFile = (flagsAsInt & kFSEventStreamEventFlagItemIsFile) != 0
        isDirectory = (flagsAsInt & kFSEventStreamEventFlagItemIsDir) != 0
        isSymlink = (flagsAsInt & kFSEventStreamEventFlagItemIsSymlink) != 0
        wasCreated = (flagsAsInt & kFSEventStreamEventFlagItemCreated) != 0
        wasRemoved = (flagsAsInt & kFSEventStreamEventFlagItemRemoved) != 0
        wasRenamed = (flagsAsInt & kFSEventStreamEventFlagItemRenamed) != 0
        wasModified = (flagsAsInt & kFSEventStreamEventFlagItemModified) != 0
        rootChanged = (flagsAsInt & kFSEventStreamEventFlagRootChanged) != 0
    }

    /// Convenience initializer for tests — builds an observation with
    /// only the flag dimensions specified, all others false.
    public init(
        path: String,
        isFile: Bool = false,
        isDirectory: Bool = false,
        isSymlink: Bool = false,
        wasCreated: Bool = false,
        wasRemoved: Bool = false,
        wasRenamed: Bool = false,
        wasModified: Bool = false,
        requiresReconciliation: Bool = false,
        rootChanged: Bool = false,
        eventID: UInt64? = nil
    ) {
        self.eventID = eventID
        self.path = path
        self.isFile = isFile
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.wasCreated = wasCreated
        self.wasRemoved = wasRemoved
        self.wasRenamed = wasRenamed
        self.wasModified = wasModified
        self.requiresReconciliation = requiresReconciliation
        self.rootChanged = rootChanged
    }
}
