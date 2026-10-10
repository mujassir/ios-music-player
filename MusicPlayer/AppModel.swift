import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let library: LibraryStore
    let player: PlayerController
    @Published var songSort: SongSort {
        didSet { UserDefaults.standard.set(songSort.rawValue, forKey: Self.songSortKey) }
    }
    @Published var songSortOrder: SongSortOrder {
        didSet { UserDefaults.standard.set(songSortOrder.rawValue, forKey: Self.songSortOrderKey) }
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        songSort = UserDefaults.standard.string(forKey: Self.songSortKey).flatMap(SongSort.init(rawValue:)) ?? .modified
        songSortOrder = UserDefaults.standard.string(forKey: Self.songSortOrderKey).flatMap(SongSortOrder.init(rawValue:)) ?? .descending
        let library = LibraryStore()
        let player = PlayerController(library: library)
        self.library = library
        self.player = player
        player.restore()
        library.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        player.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func playSongInItsFolder(_ track: Track) {
        let parent = (track.relativePath as NSString).deletingLastPathComponent
        let songs = library.tracks.filter {
            $0.folderID == track.folderID && ($0.relativePath as NSString).deletingLastPathComponent == parent
        }
        let ordered = sortedSongs(songs, by: songSort, order: songSortOrder)
        player.play(tracks: ordered.isEmpty ? [track] : ordered, startingAt: track)
    }

    private static let songSortKey = "MusicPlayer.songSort"
    private static let songSortOrderKey = "MusicPlayer.songSortOrder"
}
