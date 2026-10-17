import AppKit
import Combine
import SwiftUI

private enum AudioPreviewSymbol {
    static func name(isPlaying: Bool) -> String {
        isPlaying ? "stop.fill" : "play.fill"
    }

    static func help(isPlaying: Bool, isAvailable: Bool) -> String {
        guard isAvailable else { return AudioPreviewMessages.unavailable }
        return isPlaying ? AudioPreviewMessages.stop : AudioPreviewMessages.play
    }
}

/// Play/stop control for SwiftUI rows.
struct AudioPreviewButton: View {
    @ObservedObject var player: AudioPreviewPlayer
    let fileID: Int64
    let path: String
    var isAvailable = true

    var body: some View {
        let isPlaying = player.playingFileID == fileID
        Button {
            player.toggle(fileID: fileID, path: path)
        } label: {
            Image(systemName: AudioPreviewSymbol.name(isPlaying: isPlaying))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
        .disabled(!isAvailable && !isPlaying)
        .help(AudioPreviewSymbol.help(isPlaying: isPlaying, isAvailable: isAvailable))
        .accessibilityLabel(AudioPreviewMessages.accessibilityLabel(isPlaying: isPlaying, track: (path as NSString).lastPathComponent))
    }
}

/// Shows why the last preview could not start or stopped early.
struct AudioPreviewFailureMessage: View {
    @ObservedObject var player: AudioPreviewPlayer

    var body: some View {
        if let failure = player.failure {
            ActionErrorMessage(message: failure)
        }
    }
}

/// Play/stop control for AppKit table rows. Reused cells follow the
/// player's state for whichever row they currently show.
final class AudioPreviewCell: NSTableCellView {
    private let button = NSButton()
    private var subscription: AnyCancellable?
    private var player: AudioPreviewPlayer?
    private var row: (fileID: Int64, path: String, track: String, isAvailable: Bool)?

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
        fatalError("Preview cells are created programmatically")
    }

    override func layout() {
        super.layout()
        button.frame = bounds
    }

    func update(row: BrowserRow?, player: AudioPreviewPlayer) {
        self.row = row.map { current in
            (current.id, current.path, current.title ?? current.filenameOnly, current.fileAvailability == .available)
        }
        if self.player !== player {
            self.player = player
            subscription = player.$playingFileID.sink { [weak self] playingFileID in
                self?.render(playingFileID: playingFileID)
            }
        } else {
            render(playingFileID: player.playingFileID)
        }
    }

    private func render(playingFileID: Int64?) {
        guard let row else {
            button.isHidden = true
            return
        }
        let isPlaying = playingFileID == row.fileID
        button.isHidden = false
        button.image = NSImage(systemSymbolName: AudioPreviewSymbol.name(isPlaying: isPlaying), accessibilityDescription: nil)
        button.contentTintColor = isPlaying ? .controlAccentColor : .secondaryLabelColor
        button.isEnabled = row.isAvailable || isPlaying
        button.toolTip = AudioPreviewSymbol.help(isPlaying: isPlaying, isAvailable: row.isAvailable)
        button.setAccessibilityLabel(AudioPreviewMessages.accessibilityLabel(isPlaying: isPlaying, track: row.track))
    }

    @objc private func toggle() {
        guard let row, let player else { return }
        player.toggle(fileID: row.fileID, path: row.path)
    }
}
