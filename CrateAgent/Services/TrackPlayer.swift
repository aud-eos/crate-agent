import AVFoundation
import Combine
import Foundation

/// A library file the player can play, with the labels shown while it plays.
struct PlayerTrack: Equatable {
    let fileID: Int64
    let path: String
    var title: String?
    var artist: String?

    var filename: String {
        (path as NSString).lastPathComponent
    }

    /// The title, else the filename.
    var displayTitle: String {
        title.flatMap { $0.isEmpty ? nil : $0 } ?? filename
    }
}

extension PlayerTrack {
    init(_ row: BrowserRow) {
        self.init(fileID: row.id, path: row.path, title: row.title, artist: row.artist)
    }
}

enum TrackPlayerState: Equatable {
    case idle
    /// Pressed, but its file is still being checked; shown as playing, so a
    /// second press cancels it.
    case verifying(PlayerTrack)
    case playing(PlayerTrack)
    case paused(PlayerTrack)

    var track: PlayerTrack? {
        switch self {
        case .idle: nil
        case let .verifying(track), let .playing(track), let .paused(track): track
        }
    }

    var isPlaying: Bool {
        switch self {
        case .verifying, .playing: true
        case .idle, .paused: false
        }
    }
}

/// Elapsed time for the current track. Kept apart from the player so
/// frequent position ticks re-render only the now-playing bar, not every
/// row's play button.
@MainActor
final class TrackPlayerPosition: ObservableObject {
    @Published fileprivate(set) var elapsed: TimeInterval = 0
    @Published fileprivate(set) var duration: TimeInterval = 0

    var fraction: Double {
        duration > 0 ? min(1, max(0, elapsed / duration)) : 0
    }
}

/// The app's one audio player: every panel's play buttons and the
/// now-playing bar drive it, so only one track plays app-wide. Playback
/// only: it never writes the file, its tags, or Serato's library, so it
/// needs no `OperationEngine` mutation and no Serato-running gate.
@MainActor
final class TrackPlayer: ObservableObject {
    /// Row play buttons start part-way in, past typical DJ intros, then play to the end.
    static let previewStartFraction = 0.3
    static let skipInterval: TimeInterval = 10

    @Published private(set) var state: TrackPlayerState = .idle
    @Published private(set) var failure: String?
    let position = TrackPlayerPosition()

    private let output: TrackPlayerOutput
    private let access: LibraryFileAccess
    private var playbackGeneration = 0

    init(output: TrackPlayerOutput, access: LibraryFileAccess) {
        self.output = output
        self.access = access
    }

    convenience init(access: LibraryFileAccess) {
        self.init(output: AVTrackPlayerOutput(), access: access)
    }

    var track: PlayerTrack? {
        state.track
    }

    func isPlaying(fileID: Int64) -> Bool {
        state.isPlaying && track?.fileID == fileID
    }

    /// Stops the current track and plays `track` from `startFraction` of its
    /// length, once its row is confirmed available and its file is still
    /// that row's recording.
    func play(_ track: PlayerTrack, from startFraction: Double) async {
        stop()
        failure = nil
        let generation = playbackGeneration
        state = .verifying(track)
        let record: FileRecord
        do {
            record = try await access.verifiedRecord(fileID: track.fileID)
        } catch {
            guard playbackGeneration == generation else { return }
            state = .idle
            failure = (error as? LibraryFileAccessError).map { error in TrackPlayerMessages.cannotPlay(error.filename, detail: error.detail) }
                ?? TrackPlayerMessages.cannotPlay(track.filename, detail: error.localizedDescription)
            return
        }
        guard playbackGeneration == generation else { return }
        state = .playing(track)
        output.play(URL(fileURLWithPath: record.path), from: startFraction, onProgress: { [weak self] elapsed, duration in
            guard let self, playbackGeneration == generation else { return }
            position.elapsed = elapsed
            position.duration = duration
        }, onEnd: { [weak self] problem in
            guard let self, playbackGeneration == generation else { return }
            stop()
            if let problem {
                failure = TrackPlayerMessages.failed(track.filename, reason: problem)
            }
        })
    }

    /// A row button press: pauses or resumes `track` in place when it is
    /// current; otherwise plays it as a preview.
    func toggle(_ track: PlayerTrack) async {
        if self.track?.fileID == track.fileID {
            togglePlayback()
        } else {
            await play(track, from: Self.previewStartFraction)
        }
    }

    func togglePlayback() {
        switch state {
        case .idle: break
        case .verifying: stop()
        case .playing: pause()
        case .paused: resume()
        }
    }

    func pause() {
        guard case let .playing(track) = state else { return }
        output.pause()
        state = .paused(track)
    }

    func resume() {
        guard case let .paused(track) = state else { return }
        output.resume()
        state = .playing(track)
    }

    func seek(toFraction fraction: Double) {
        seek(toSeconds: min(1, max(0, fraction)) * position.duration)
    }

    func skip(by seconds: TimeInterval) {
        seek(toSeconds: position.elapsed + seconds)
    }

    func dismissFailure() {
        failure = nil
    }

    func stop() {
        playbackGeneration += 1
        output.stop()
        state = .idle
        position.elapsed = 0
        position.duration = 0
    }

    private func seek(toSeconds seconds: TimeInterval) {
        guard track != nil, position.duration > 0 else { return }
        let target = min(position.duration, max(0, seconds))
        position.elapsed = target
        output.seek(toSeconds: target)
    }
}

/// The audio device boundary. `onProgress` reports elapsed and total
/// seconds; `onEnd` receives nil when playback reaches the end, or a reason
/// when it fails, including a stall that outlasts `stallTimeout`. A callback already queued when `stop()` runs can still
/// arrive, so the player ignores stale ones.
@MainActor
protocol TrackPlayerOutput: AnyObject {
    func play(_ url: URL, from startFraction: Double,
              onProgress: @escaping @MainActor (TimeInterval, TimeInterval) -> Void,
              onEnd: @escaping @MainActor (String?) -> Void)
    func pause()
    func resume()
    func seek(toSeconds seconds: TimeInterval)
    func stop()
}

@MainActor
final class AVTrackPlayerOutput: TrackPlayerOutput {
    private static let progressInterval = CMTime(value: 1, timescale: 4)
    private static let timescale: CMTimeScale = 600
    /// How long playback may wait for data, e.g. after its volume is ejected, before it fails visibly.
    static let stallTimeout: Duration = .seconds(5)

    private let player = AVPlayer()
    private var subscriptions: Set<AnyCancellable> = []
    private var timeObserver: Any?
    private var isPaused = false
    private var stallTimer: Task<Void, Never>?

    func play(_ url: URL, from startFraction: Double,
              onProgress: @escaping @MainActor (TimeInterval, TimeInterval) -> Void,
              onEnd: @escaping @MainActor (String?) -> Void)
    {
        stop()
        isPaused = false
        let item = AVPlayerItem(url: url)
        let center = NotificationCenter.default
        center.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.finish(item, onEnd, reason: nil)
            }
            .store(in: &subscriptions)
        center.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.finish(item, onEnd, reason: error?.localizedDescription ?? TrackPlayerMessages.unknownFailure)
            }
            .store(in: &subscriptions)
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.watchForStall(item, status: status, onEnd: onEnd)
            }
            .store(in: &subscriptions)
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item else { return }
                switch status {
                case .failed:
                    finish(item, onEnd, reason: item.error?.localizedDescription ?? TrackPlayerMessages.unknownFailure)
                case .readyToPlay:
                    start(item, from: startFraction)
                default:
                    break
                }
            }
            .store(in: &subscriptions)
        timeObserver = player.addPeriodicTimeObserver(forInterval: Self.progressInterval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let duration = self?.durationSeconds else { return }
                onProgress(max(0, time.seconds), duration)
            }
        }
        player.replaceCurrentItem(with: item)
    }

    func pause() {
        isPaused = true
        player.pause()
    }

    func resume() {
        isPaused = false
        player.play()
    }

    func seek(toSeconds seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: Self.timescale))
    }

    func stop() {
        stallTimer?.cancel()
        stallTimer = nil
        subscriptions.removeAll()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private var durationSeconds: TimeInterval? {
        guard let duration = player.currentItem?.duration, duration.isNumeric, duration.seconds > 0 else { return nil }
        return duration.seconds
    }

    private func start(_ item: AVPlayerItem, from startFraction: Double) {
        guard player.currentItem === item, item.currentTime().seconds == 0 else { return }
        guard let duration = durationSeconds, startFraction > 0 else {
            playIfCurrent(item)
            return
        }
        player.seek(to: CMTime(seconds: duration * startFraction, preferredTimescale: Self.timescale)) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.playIfCurrent(item)
                }
            }
        }
    }

    private func playIfCurrent(_ item: AVPlayerItem) {
        guard player.currentItem === item, !isPaused else { return }
        player.play()
    }

    /// Waiting for data, not paused by the user, starts the stall clock; any other state stops it.
    private func watchForStall(_ item: AVPlayerItem, status: AVPlayer.TimeControlStatus, onEnd: @escaping @MainActor (String?) -> Void) {
        stallTimer?.cancel()
        stallTimer = nil
        guard status == .waitingToPlayAtSpecifiedRate, player.currentItem === item, item.status == .readyToPlay else { return }
        stallTimer = Task { [weak self] in
            guard await (try? Task.sleep(for: Self.stallTimeout)) != nil else { return }
            self?.finish(item, onEnd, reason: TrackPlayerMessages.stalled)
        }
    }

    private func finish(_ item: AVPlayerItem, _ onEnd: @MainActor (String?) -> Void, reason: String?) {
        guard player.currentItem === item else { return }
        stop()
        onEnd(reason)
    }
}
