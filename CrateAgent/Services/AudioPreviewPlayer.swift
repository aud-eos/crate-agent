import AVFoundation
import Combine
import Foundation

/// Plays one library file at a time for auditioning. Playback only: it
/// never writes the file, its tags, or Serato's library, so it needs no
/// `OperationEngine` mutation and no Serato-running gate.
@MainActor
final class AudioPreviewPlayer: ObservableObject {
    @Published private(set) var playingFileID: Int64?
    @Published private(set) var failure: String?

    private let output: AudioPreviewOutput
    private var playbackGeneration = 0

    init(output: AudioPreviewOutput) {
        self.output = output
    }

    convenience init() {
        self.init(output: AVPlayerPreviewOutput())
    }

    /// Stops `fileID` if it is playing; otherwise stops any other preview
    /// and starts this one from the beginning.
    func toggle(fileID: Int64, path: String) {
        if playingFileID == fileID {
            stop()
            return
        }
        stop()
        let filename = (path as NSString).lastPathComponent
        guard FileManager.default.isReadableFile(atPath: path) else {
            failure = AudioPreviewMessages.unreadable(filename)
            return
        }
        failure = nil
        playingFileID = fileID
        let generation = playbackGeneration
        output.play(URL(fileURLWithPath: path)) { [weak self] problem in
            guard let self, playbackGeneration == generation else { return }
            playingFileID = nil
            if let problem {
                failure = AudioPreviewMessages.failed(filename, reason: problem)
            }
        }
    }

    func stop() {
        playbackGeneration += 1
        output.stop()
        playingFileID = nil
    }
}

/// The audio device boundary. `onEnd` receives nil when playback reaches
/// the end, or a reason when it fails. A notification already queued when
/// `stop()` runs can still arrive, so the player ignores stale ones.
@MainActor
protocol AudioPreviewOutput: AnyObject {
    func play(_ url: URL, onEnd: @escaping @MainActor (String?) -> Void)
    func stop()
}

@MainActor
final class AVPlayerPreviewOutput: AudioPreviewOutput {
    private let player = AVPlayer()
    private var subscriptions: Set<AnyCancellable> = []

    func play(_ url: URL, onEnd: @escaping @MainActor (String?) -> Void) {
        stop()
        let item = AVPlayerItem(url: url)
        let center = NotificationCenter.default
        center.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.finish(onEnd, reason: nil)
            }
            .store(in: &subscriptions)
        center.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.finish(onEnd, reason: error?.localizedDescription ?? AudioPreviewMessages.unknownFailure)
            }
            .store(in: &subscriptions)
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard status == .failed else { return }
                self?.finish(onEnd, reason: item?.error?.localizedDescription ?? AudioPreviewMessages.unknownFailure)
            }
            .store(in: &subscriptions)
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func stop() {
        subscriptions.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func finish(_ onEnd: @MainActor (String?) -> Void, reason: String?) {
        stop()
        onEnd(reason)
    }
}
