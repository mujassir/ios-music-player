import AVFoundation
import MediaPlayer
import Foundation

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var isScrubbing = false

    private let library: LibraryStore
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var didRestore = false

    init(library: LibraryStore) {
        self.library = library
        configureSession()
        #if os(iOS)
        configureRemoteCommands()
        #else
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
        observePlayback()
    }

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    func restore() {
        guard !didRestore else { return }
        didRestore = true
        guard let data = UserDefaults.standard.data(forKey: Self.resumeKey),
              let resume = try? JSONDecoder().decode(ResumeState.self, from: data) else {
            return
        }
        let restored = resume.queueIDs.compactMap { id in library.tracks.first { $0.id == id } }
        guard !restored.isEmpty else { return }
        queue = restored
        shuffle = resume.shuffle
        repeatMode = resume.repeatMode
        let index = restored.indices.contains(resume.index) ? resume.index : 0
        #if os(macOS)
        load(index: index, autoplay: true, time: resume.time)
        #else
        load(index: index, autoplay: false, time: resume.time)
        #endif
    }

    func play(tracks: [Track], startingAt track: Track) {
        guard !tracks.isEmpty else { return }
        var ordered = tracks
        if shuffle {
            ordered.shuffle()
            if let index = ordered.firstIndex(where: { $0.id == track.id }), index != 0 {
                ordered.swapAt(0, index)
            }
        }
        queue = ordered
        guard let index = ordered.firstIndex(where: { $0.id == track.id }) else { return }
        load(index: index, autoplay: true, time: 0)
    }

    func playQueued(at index: Int) {
        load(index: index, autoplay: true, time: 0)
    }

    func toggle() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard currentTrack != nil else { return }
        configureSession()
        player.play()
        updateNowPlaying(rate: 1)
        persist()
    }

    func pause() {
        player.pause()
        updateNowPlaying(rate: 0)
        persist()
    }

    func next() {
        guard !queue.isEmpty, let index = currentIndex else { return }
        if repeatMode == .all || index + 1 < queue.count {
            load(index: (index + 1) % queue.count, autoplay: true, time: 0)
        }
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard let index = currentIndex, !queue.isEmpty else { return }
        if index > 0 {
            load(index: index - 1, autoplay: true, time: 0)
        } else if repeatMode == .all {
            load(index: queue.count - 1, autoplay: true, time: 0)
        } else {
            seek(to: 0)
        }
    }

    func seek(to time: TimeInterval) {
        let upper = duration > 0 ? duration : time
        let clamped = min(max(0, time), upper)
        currentTime = clamped
        isScrubbing = true
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = clamped
                self.isScrubbing = false
                self.updateNowPlaying(rate: self.isPlaying ? 1 : 0)
                self.persist()
            }
        }
    }

    func toggleShuffle() {
        shuffle.toggle()
        guard let track = currentTrack else {
            persist()
            return
        }
        if shuffle {
            var upcoming = queue
            upcoming.removeAll { $0.id == track.id }
            upcoming.shuffle()
            queue = [track] + upcoming
            currentIndex = 0
        }
        persist()
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        persist()
        updateNowPlaying(rate: isPlaying ? 1 : 0)
    }

    func artworkImage(for track: Track) -> PlatformImage? {
        guard let url = library.artworkURL(for: track),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return PlatformImage(data: data)
    }

    private func load(index: Int, autoplay: Bool, time: TimeInterval) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        guard let url = library.url(for: track) else {
            queue.remove(at: index)
            if queue.isEmpty {
                currentIndex = nil
                player.replaceCurrentItem(with: nil)
                return
            }
            load(index: min(index, queue.count - 1), autoplay: autoplay, time: 0)
            return
        }
        currentIndex = index
        duration = track.duration
        currentTime = time
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if time > 0 {
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        }
        if autoplay {
            configureSession()
            player.play()
        } else {
            player.pause()
        }
        updateNowPlaying(rate: autoplay ? 1 : 0)
        persist()
    }

    private func observePlayback() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                self.currentTime = seconds
            }
            if let itemDuration = self.player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                self.duration = itemDuration
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let item = notification.object as? AVPlayerItem, item == self.player.currentItem else { return }
            self.handleEnded()
        }
        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
    }

    private func handleEnded() {
        switch repeatMode {
        case .one:
            seek(to: 0)
            play()
        case .all:
            next()
        case .off:
            if let index = currentIndex, index + 1 < queue.count {
                load(index: index + 1, autoplay: true, time: 0)
            } else {
                pause()
            }
        }
    }

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    #if os(iOS)
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            self?.performOnMain { $0.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.performOnMain { $0.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.performOnMain { $0.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.performOnMain { $0.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.performOnMain { $0.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.performOnMain { $0.seek(to: event.positionTime) }
            return .success
        }
    }
    private func performOnMain(_ action: @escaping (PlayerController) -> Void) {
        Task { @MainActor in
            action(self)
        }
    }
    #endif

    private func updateNowPlaying(rate: Double) {
        #if os(macOS)
        return
        #else
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration > 0 ? duration : track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: rate
        ]
        if let image = artworkImage(for: track) {
            let size = image.size
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    private func persist() {
        let resume = ResumeState(
            trackID: currentTrack?.id,
            time: currentTime,
            queueIDs: queue.map(\.id),
            index: currentIndex ?? 0,
            shuffle: shuffle,
            repeatMode: repeatMode
        )
        if let data = try? JSONEncoder().encode(resume) {
            UserDefaults.standard.set(data, forKey: Self.resumeKey)
        }
    }

    private static let resumeKey = "MusicPlayer.Resume"
}

private struct ResumeState: Codable {
    var trackID: UUID?
    var time: TimeInterval
    var queueIDs: [UUID]
    var index: Int
    var shuffle: Bool
    var repeatMode: RepeatMode
}
