#if os(iOS)
import AppIntents
import Foundation

// MARK: - Entities

/// A song in the library, searchable by Siri, Shortcuts and Spotlight.
struct SongEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song")
    static var defaultQuery = SongQuery()

    var id: UUID
    var title: String
    var artist: String
    var artworkURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(artist)",
            image: artworkURL.map { .init(url: $0) } ?? .init(systemName: "music.note")
        )
    }

    @MainActor
    init(_ track: Track, library: LibraryStore) {
        id = track.id
        title = track.title
        artist = track.artist
        artworkURL = library.artworkURL(for: track)
    }
}

struct SongQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SongEntity] {
        let library = AppModel.shared.library
        let wanted = Set(identifiers)
        return library.tracks.filter { wanted.contains($0.id) }.map { SongEntity($0, library: library) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SongEntity] {
        let library = AppModel.shared.library
        let query = MusicSearch.normalize(string)
        guard !query.isEmpty else { return [] }
        return library.tracks
            .filter {
                MusicSearch.normalize($0.title).contains(query)
                    || MusicSearch.normalize($0.artist).contains(query)
                    || MusicSearch.normalize($0.album).contains(query)
            }
            .prefix(50)
            .map { SongEntity($0, library: library) }
    }

    /// Siri matches spoken App Shortcut phrases ("Play <song> in Cassette") against these.
    @MainActor
    func suggestedEntities() async throws -> [SongEntity] {
        let library = AppModel.shared.library
        return library.tracks.prefix(500).map { SongEntity($0, library: library) }
    }
}

/// A folder of songs, the same groups the library and CarPlay show.
struct FolderEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Folder")
    static var defaultQuery = FolderQuery()

    var id: String
    var name: String
    var songCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: songCount == 1 ? "1 song" : "\(songCount) songs",
            image: .init(systemName: "folder.fill")
        )
    }

    init(_ folder: PlayableFolder) {
        id = folder.id
        name = folder.name
        songCount = folder.tracks.count
    }
}

struct FolderQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [FolderEntity] {
        let wanted = Set(identifiers)
        return PlayableFolder.all(in: AppModel.shared.library).filter { wanted.contains($0.id) }.map(FolderEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [FolderEntity] {
        let query = MusicSearch.normalize(string)
        return PlayableFolder.all(in: AppModel.shared.library)
            .filter { MusicSearch.normalize($0.name).contains(query) }
            .map(FolderEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [FolderEntity] {
        PlayableFolder.all(in: AppModel.shared.library).map(FolderEntity.init)
    }
}

// MARK: - Intents

enum CassetteIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notFound
    case emptyLibrary

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notFound: return "That isn't in your Cassette library."
        case .emptyLibrary: return "Your Cassette library is empty. Add a music folder in the app first."
        }
    }
}

/// `AudioPlaybackIntent` lets Siri start playback without bringing the app to the foreground.
struct PlaySongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Song"
    static var description = IntentDescription("Plays a song from your library, followed by the rest of its folder.")

    @Parameter(title: "Song")
    var song: SongEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$song)")
    }

    init() {}
    init(song: SongEntity) { self.song = song }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppModel.shared
        guard let track = app.library.tracks.first(where: { $0.id == song.id }) else {
            throw CassetteIntentError.notFound
        }
        MusicSearch.play(MusicSearch.songQueue(track, app: app), in: app)
        return .result(dialog: "Playing \(track.title).")
    }
}

struct PlayFolderIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Folder"
    static var description = IntentDescription("Plays every song in a folder.")

    @Parameter(title: "Folder")
    var folder: FolderEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$folder)") { \.$shuffle }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppModel.shared
        guard let found = PlayableFolder.all(in: app.library).first(where: { $0.id == folder.id }),
              let match = MusicSearch.folderQueue(found, app: app) else {
            throw CassetteIntentError.notFound
        }
        MusicSearch.play(match, shuffle: shuffle, in: app)
        return .result(dialog: "Playing \(found.name).")
    }
}

/// "Play music in Cassette": search by any name (song, folder, album or artist), or shuffle everything.
struct PlayMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Music"
    static var description = IntentDescription("Finds a song, folder, album or artist by name and plays it. Leave the name empty to shuffle your whole library.")

    @Parameter(title: "Name", requestValueDialog: "What would you like to hear?")
    var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$name)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppModel.shared
        guard !app.library.tracks.isEmpty else { throw CassetteIntentError.emptyLibrary }
        guard let match = MusicSearch.find(name: name, artist: nil, album: nil, kind: nil, in: app) else {
            throw CassetteIntentError.notFound
        }
        MusicSearch.play(match, in: app)
        return .result(dialog: "Playing \(match.title).")
    }
}

struct ShuffleAllIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle All Songs"
    static var description = IntentDescription("Shuffles your whole library.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppModel.shared
        guard let match = MusicSearch.libraryMatch(app.library.tracks) else {
            throw CassetteIntentError.emptyLibrary
        }
        MusicSearch.play(match, shuffle: true, in: app)
        return .result(dialog: "Shuffling your library.")
    }
}

// MARK: - Siri phrases

struct CassetteShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaySongIntent(),
            phrases: [
                "Play \(\.$song) in \(.applicationName)",
                "Play \(\.$song) on \(.applicationName)",
                "Play the song \(\.$song) in \(.applicationName)"
            ],
            shortTitle: "Play Song",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: PlayFolderIntent(),
            phrases: [
                "Play \(\.$folder) in \(.applicationName)",
                "Play \(\.$folder) on \(.applicationName)",
                "Play folder \(\.$folder) in \(.applicationName)"
            ],
            shortTitle: "Play Folder",
            systemImageName: "folder.fill"
        )
        AppShortcut(
            intent: ShuffleAllIntent(),
            phrases: [
                "Shuffle \(.applicationName)",
                "Shuffle my music in \(.applicationName)",
                "Shuffle songs in \(.applicationName)"
            ],
            shortTitle: "Shuffle All",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Play music in \(.applicationName)",
                "Play something in \(.applicationName)",
                "Search \(.applicationName)"
            ],
            shortTitle: "Play Music",
            systemImageName: "play.fill"
        )
    }
}
#endif
