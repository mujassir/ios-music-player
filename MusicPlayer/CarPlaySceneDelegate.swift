#if os(iOS)
import CarPlay
import Combine
import UIKit

/// CarPlay interface: Library (folders) → songs in a folder → system Now Playing.
/// It shares `AppModel.shared` with the phone UI, so the library, queue and
/// playback state are the same on both screens.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private let rootTemplate = CPListTemplate(title: "Library", sections: [])
    private var libraryObserver: AnyCancellable?

    private var app: AppModel { AppModel.shared }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        rootTemplate.emptyViewTitleVariants = ["No Music Yet"]
        rootTemplate.emptyViewSubtitleVariants = ["Add a music folder in Cassette on your iPhone."]
        reloadFolders()
        interfaceController.setRootTemplate(rootTemplate, animated: false, completion: nil)

        // Keep the folder list current when the library is rescanned or a folder is added on the phone.
        libraryObserver = app.library.$tracks
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadFolders() }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        libraryObserver = nil
        self.interfaceController = nil
    }

    // MARK: - Folders

    private func reloadFolders() {
        let limit = CPListTemplate.maximumItemCount
        let items = PlayableFolder.all(in: app.library).prefix(limit).map { folder -> CPListItem in
            let count = folder.tracks.count
            let item = CPListItem(
                text: folder.name,
                detailText: count == 1 ? "1 song" : "\(count) songs",
                image: UIImage(systemName: "folder.fill")
            )
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.showSongs(in: folder)
                completion()
            }
            return item
        }
        rootTemplate.updateSections([CPListSection(items: Array(items))])
    }

    // MARK: - Songs

    private func showSongs(in folder: PlayableFolder) {
        let songs = sortedSongs(folder.tracks, by: app.songSort, order: app.songSortOrder)
        let thumbnailSize = CPListItem.maximumImageSize
        let items = songs.prefix(CPListTemplate.maximumItemCount).map { track -> CPListItem in
            let item = CPListItem(
                text: track.title,
                detailText: track.artist,
                image: artwork(for: track, size: thumbnailSize) ?? UIImage(systemName: "music.note")
            )
            item.isPlaying = app.player.currentTrack?.id == track.id
            item.handler = { [weak self] _, completion in
                self?.play(track, in: songs)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: folder.name, sections: [CPListSection(items: Array(items))])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func play(_ track: Track, in songs: [Track]) {
        app.player.play(tracks: songs, startingAt: track)
        showNowPlaying()
    }

    private func showNowPlaying() {
        guard let interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if interfaceController.topTemplate === nowPlaying { return }
        interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
    }

    // MARK: - Artwork

    private func artwork(for track: Track, size: CGSize) -> UIImage? {
        guard let url = app.library.artworkURL(for: track),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return image.preparingThumbnail(of: size) ?? image
    }
}

/// One folder of songs, grouped the same way as the phone's sidebar:
/// by library folder and the song's parent directory. Used by CarPlay and Siri.
struct PlayableFolder {
    var id: String
    var name: String
    var tracks: [Track]

    @MainActor
    static func all(in library: LibraryStore) -> [PlayableFolder] {
        struct Key: Hashable { let folderID: UUID; let path: String }
        let grouped = Dictionary(grouping: library.tracks) {
            Key(folderID: $0.folderID, path: ($0.relativePath as NSString).deletingLastPathComponent)
        }
        let libraryNames = Dictionary(uniqueKeysWithValues: library.folders.map { ($0.id, $0.name) })

        var folders = grouped.map { key, tracks -> (Key, PlayableFolder) in
            let name = key.path.isEmpty
                ? (libraryNames[key.folderID] ?? "Music")
                : (key.path as NSString).lastPathComponent
            return (key, PlayableFolder(id: "\(key.folderID.uuidString)/\(key.path)", name: name, tracks: tracks))
        }

        // Disambiguate folders that share a name by adding their parent ("Parent / Name").
        let nameCounts = Dictionary(grouping: folders, by: { $0.1.name }).mapValues(\.count)
        for index in folders.indices where nameCounts[folders[index].1.name, default: 0] > 1 {
            let key = folders[index].0
            guard !key.path.isEmpty else { continue }
            let parent = (key.path as NSString).deletingLastPathComponent
            let parentName = parent.isEmpty
                ? (libraryNames[key.folderID] ?? "")
                : (parent as NSString).lastPathComponent
            if !parentName.isEmpty {
                folders[index].1.name = "\(parentName) / \(folders[index].1.name)"
            }
        }

        return folders.map(\.1).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
#endif
