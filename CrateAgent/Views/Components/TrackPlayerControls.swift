import AppKit
import Combine
import SwiftUI

private enum TrackPlayerSymbol {
    static func name(isPlaying: Bool) -> String {
        isPlaying ? "pause.fill" : "play.fill"
    }

    static func help(isCurrent: Bool, isPlaying: Bool, isAvailable: Bool) -> String {
        guard isAvailable || isCurrent else { return TrackPlayerMessages.unavailable }
        return TrackPlayerMessages.action(isCurrent: isCurrent, isPlaying: isPlaying)
    }

    static func time(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: .minuteSecond))
    }
}

/// Play/pause control for SwiftUI rows.
struct TrackPlayButton: View {
    @ObservedObject var player: TrackPlayer
    let track: PlayerTrack
    var isAvailable = true

    var body: some View {
        let isCurrent = player.track?.fileID == track.fileID
        let isPlaying = player.isPlaying(fileID: track.fileID)
        Button {
            Task { await player.toggle(track) }
        } label: {
            Image(systemName: TrackPlayerSymbol.name(isPlaying: isPlaying))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        .disabled(!isAvailable && !isCurrent)
        .help(TrackPlayerSymbol.help(isCurrent: isCurrent, isPlaying: isPlaying, isAvailable: isAvailable))
        .accessibilityLabel(TrackPlayerMessages.accessibilityLabel(isCurrent: isCurrent, isPlaying: isPlaying, track: track.displayTitle))
    }
}

/// The window-wide now-playing bar: title and artist, play/pause, ±10 s
/// skip, a full-length scrub bar and stop, plus why playback last failed.
struct NowPlayingBar: View {
    @ObservedObject var player: TrackPlayer
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable

    var body: some View {
        if player.track != nil || player.failure != nil {
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                if let failure = player.failure {
                    HStack(spacing: density.spacing) {
                        ActionErrorMessage(message: failure)
                        Spacer(minLength: density.spacing)
                        Button(CommonLabels.dismiss, action: player.dismissFailure)
                            .accessibilityLabel(TrackPlayerMessages.dismissFailure)
                    }
                }
                if let track = player.track {
                    HStack(spacing: density.spacing) {
                        Button(TrackPlayerMessages.skipBack, systemImage: "gobackward.10") { player.skip(by: -TrackPlayer.skipInterval) }
                        Button {
                            player.togglePlayback()
                        } label: {
                            Image(systemName: TrackPlayerSymbol.name(isPlaying: player.state.isPlaying))
                        }
                        .help(TrackPlayerMessages.action(isCurrent: true, isPlaying: player.state.isPlaying))
                        .accessibilityLabel(TrackPlayerMessages.accessibilityLabel(isCurrent: true, isPlaying: player.state.isPlaying, track: track.displayTitle))
                        Button(TrackPlayerMessages.skipForward, systemImage: "goforward.10") { player.skip(by: TrackPlayer.skipInterval) }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(track.displayTitle).font(.callout.weight(.medium))
                            if let artist = track.artist, !artist.isEmpty {
                                Text(artist).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
                        .help(track.path)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(TrackPlayerMessages.nowPlayingLabel(title: track.displayTitle, artist: track.artist))
                        TrackPlayerScrubber(position: player.position, seek: player.seek(toFraction:))
                        Button(TrackPlayerMessages.stop, systemImage: "stop.fill", action: player.stop)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, density.pagePadding)
            .padding(.vertical, density.rowPadding)
            Divider()
        }
    }
}

private struct TrackPlayerScrubber: View {
    @ObservedObject var position: TrackPlayerPosition
    let seek: (Double) -> Void
    @State private var draggedFraction: Double?

    var body: some View {
        let fraction = draggedFraction ?? position.fraction
        let elapsed = TrackPlayerSymbol.time(fraction * position.duration)
        let duration = TrackPlayerSymbol.time(position.duration)
        HStack(spacing: 6) {
            Text(elapsed)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { fraction }, set: { draggedFraction = $0 }), in: 0 ... 1) { editing in
                guard !editing, let draggedFraction else { return }
                seek(draggedFraction)
                self.draggedFraction = nil
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .disabled(position.duration <= 0)
            .accessibilityLabel(TrackPlayerMessages.position)
            .accessibilityValue(TrackPlayerMessages.positionValue(elapsed: elapsed, duration: duration))
            Text(duration)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// Play/pause control for AppKit table rows. Reused cells follow the
/// player's state for whichever row they currently show.
final class TrackPlayCell: NSTableCellView {
    private let button = NSButton()
    private var subscription: AnyCancellable?
    private var player: TrackPlayer?
    private var row: (track: PlayerTrack, isAvailable: Bool)?

    init() {
        super.init(frame: .zero)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(toggle)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Play cells are created programmatically")
    }

    override func layout() {
        super.layout()
        button.frame = bounds
    }

    func update(row: BrowserRow?, player: TrackPlayer) {
        self.row = row.map { current in (PlayerTrack(current), current.fileAvailability == .available) }
        if self.player !== player {
            self.player = player
            subscription = player.$state.sink { [weak self] state in
                self?.render(state)
            }
        } else {
            render(player.state)
        }
    }

    private func render(_ state: TrackPlayerState) {
        guard let row else {
            button.isHidden = true
            return
        }
        let isCurrent = state.track?.fileID == row.track.fileID
        let isRowPlaying = isCurrent && state.isPlaying
        button.isHidden = false
        button.image = NSImage(systemSymbolName: TrackPlayerSymbol.name(isPlaying: isRowPlaying), accessibilityDescription: nil)
        button.contentTintColor = isCurrent ? .controlAccentColor : .secondaryLabelColor
        button.isEnabled = row.isAvailable || isCurrent
        button.toolTip = TrackPlayerSymbol.help(isCurrent: isCurrent, isPlaying: isRowPlaying, isAvailable: row.isAvailable)
        button.setAccessibilityLabel(TrackPlayerMessages.accessibilityLabel(isCurrent: isCurrent, isPlaying: isRowPlaying, track: row.track.displayTitle))
    }

    @objc private func toggle() {
        guard let row, let player else { return }
        Task { await player.toggle(row.track) }
    }
}
