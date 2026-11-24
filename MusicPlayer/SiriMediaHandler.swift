#if os(iOS)
import AppIntents
import Combine
import Intents
import UIKit

/// Handles SiriKit's built-in "Play <song/artist/album> on Cassette" requests, which is what
/// Siri uses in CarPlay and from the steering-wheel button. Handled in the app process, so it
/// shares `AppModel.shared` with the phone and CarPlay screens.
final class SiriMediaHandler: NSObject, INPlayMediaIntentHandling {
    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        Task { @MainActor in
            guard let match = Self.match(for: intent) else {
                completion([.unsupported()])
                return
            }
            let item = INMediaItem(identifier: match.start.id.uuidString, title: match.title, type: Self.itemType(match.kind), artwork: nil)
            completion(INPlayMediaMediaItemResolutionResult.successes(with: [item]))
        }
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        Task { @MainActor in
            let app = AppModel.shared
            let search = intent.mediaSearch
            let isResume = search == nil || (search?.reference == .currentlyPlaying && search?.mediaName == nil)
            if isResume, app.player.currentTrack != nil {
                if let shuffled = intent.playShuffled, shuffled != app.player.shuffle {
                    app.player.toggleShuffle()
                }
                app.player.play()
                completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                return
            }
            guard let match = Self.match(for: intent) else {
                completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }
            MusicSearch.play(match, shuffle: intent.playShuffled, in: app)
            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
        }
    }

    @MainActor
    private static func match(for intent: INPlayMediaIntent) -> MusicSearch.Match? {
        let app = AppModel.shared
        guard let search = intent.mediaSearch else {
            return MusicSearch.libraryMatch(app.library.tracks)
        }
        let kind: MusicSearch.Kind?
        switch search.mediaType {
        case .song: kind = .song
        case .album: kind = .album
        case .artist: kind = .artist
        case .playlist: kind = .folder
        case .music: kind = search.mediaName == nil ? .library : nil
        default: kind = nil
        }
        if kind == .library { return MusicSearch.libraryMatch(app.library.tracks) }
        return MusicSearch.find(
            name: search.mediaName,
            artist: search.artistName,
            album: search.albumName,
            kind: kind,
            in: app
        )
    }

    private static func itemType(_ kind: MusicSearch.Kind) -> INMediaItemType {
        switch kind {
        case .song: return .song
        case .folder: return .playlist
        case .album: return .album
        case .artist: return .artist
        case .library: return .music
        }
    }
}

/// Keeps Siri in step with the library: folder and artist names as vocabulary,
/// the library size, and the song list used by the App Shortcut phrases.
@MainActor
final class SiriLibrarySync {
    static let shared = SiriLibrarySync()
    private var observer: AnyCancellable?

    func start() {
        guard observer == nil else { return }
        let library = AppModel.shared.library
        observer = library.$tracks
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] tracks in self?.update(tracks) }
    }

    private func update(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }

        if INPreferences.siriAuthorizationStatus() == .notDetermined {
            INPreferences.requestSiriAuthorization { _ in }
        }

        let folders = PlayableFolder.all(in: AppModel.shared.library)
            .sorted { $0.tracks.count > $1.tracks.count }
            .map(\.name)
        INVocabulary.shared().setVocabularyStrings(NSOrderedSet(array: Array(folders.prefix(500))), of: .mediaPlaylistTitle)

        let artistCounts = Dictionary(grouping: tracks, by: \.artist).mapValues(\.count)
        let artists = artistCounts.keys
            .filter { !$0.isEmpty && $0 != "Unknown Artist" }
            .sorted { artistCounts[$0, default: 0] > artistCounts[$1, default: 0] }
        INVocabulary.shared().setVocabularyStrings(NSOrderedSet(array: Array(artists.prefix(500))), of: .mediaMusicArtistName)

        let context = INMediaUserContext()
        context.numberOfLibraryItems = tracks.count
        context.becomeCurrent()

        CassetteShortcuts.updateAppShortcutParameters()
    }
}

final class CassetteAppDelegate: NSObject, UIApplicationDelegate {
    private let mediaHandler = SiriMediaHandler()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in SiriLibrarySync.shared.start() }
        return true
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? mediaHandler : nil
    }
}
#endif
