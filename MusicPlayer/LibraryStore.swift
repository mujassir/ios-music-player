import AVFoundation
import Foundation

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
final class LibraryStore: ObservableObject {
    @Published var folders: [MusicFolder] = []
    @Published var tracks: [Track] = []
    @Published var isScanning = false
    @Published var statusMessage = ""

    private var openFolders: [UUID: URL] = [:]
    private var scanQueue: Task<Void, Never>?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        load()
        for folder in folders {
            _ = access(folder)
        }
        if tracks.isEmpty {
            for folder in folders {
                enqueueScan(folder)
            }
        } else {
            backfillDatesIfNeeded()
        }
    }

    var artists: [String] {
        Set(tracks.map(\.artist)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var albums: [AlbumGroup] {
        let groups = Set(tracks.map { AlbumGroup(artist: $0.artist, title: $0.album) })
        return groups.sorted { lhs, rhs in
            let albumOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if albumOrder != .orderedSame { return albumOrder == .orderedAscending }
            return lhs.artist.localizedCaseInsensitiveCompare(rhs.artist) == .orderedAscending
        }
    }

    var folderGroups: [FolderGroup] {
        let paths = Set(tracks.map { ($0.relativePath as NSString).deletingLastPathComponent })
        return paths.map { FolderGroup(path: $0) }.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    func tracks(byArtist artist: String) -> [Track] {
        tracks
            .filter { $0.artist == artist }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func albums(byArtist artist: String) -> [AlbumGroup] {
        albums.filter { $0.artist == artist }
    }

    func tracks(in album: AlbumGroup) -> [Track] {
        tracks
            .filter { $0.artist == album.artist && $0.album == album.title }
            .sorted(by: Self.albumOrder)
    }

    func tracks(in folder: FolderGroup) -> [Track] {
        tracks
            .filter { ($0.relativePath as NSString).deletingLastPathComponent == folder.path }
            .sorted(by: Self.albumOrder)
    }

    func sortedSongs() -> [Track] {
        tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func url(for track: Track) -> URL? {
        guard let folder = folders.first(where: { $0.id == track.folderID }) else { return nil }
        guard let root = access(folder) else { return nil }
        return root.appendingPathComponent(track.relativePath)
    }

    func artworkURL(for track: Track) -> URL? {
        guard let name = track.artworkFilename else { return nil }
        return Self.artworkDirectory.appendingPathComponent(name)
    }

    func add(urls: [URL]) {
        for url in urls {
            add(url: url)
        }
    }

    func add(url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        if folders.contains(where: { folder in
            guard let existing = access(folder) else { return false }
            return existing.standardizedFileURL.resolvingSymlinksInPath().path == standardized.path
        }) {
            statusMessage = "\(url.lastPathComponent) is already in the library."
            return
        }

        do {
            let bookmark = try url.bookmarkData(
                options: Self.bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let folder = MusicFolder(id: UUID(), name: url.lastPathComponent, bookmarkData: bookmark)
            folders.append(folder)
            save()
            enqueueScan(folder)
        } catch {
            statusMessage = "Couldn’t save access to \(url.lastPathComponent)."
        }
    }

    #if os(macOS)
    func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose a folder of music files"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                self?.add(urls: panel.urls)
            }
        }
    }
    #endif

    func remove(_ folder: MusicFolder) {
        if let url = openFolders.removeValue(forKey: folder.id) {
            url.stopAccessingSecurityScopedResource()
        }
        let removed = tracks.filter { $0.folderID == folder.id }
        for track in removed {
            if let artwork = artworkURL(for: track) {
                try? FileManager.default.removeItem(at: artwork)
            }
        }
        tracks.removeAll { $0.folderID == folder.id }
        folders.removeAll { $0.id == folder.id }
        save()
        statusMessage = "Removed \(folder.name)."
    }

    func rescanAll() {
        guard !folders.isEmpty else {
            statusMessage = "Choose a music folder first."
            return
        }
        for folder in folders {
            enqueueScan(folder)
        }
    }

    func access(_ folder: MusicFolder) -> URL? {
        if let open = openFolders[folder.id] {
            return open
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: folder.bookmarkData,
            options: Self.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale, let refreshed = try? url.bookmarkData(
            options: Self.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ), let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index].bookmarkData = refreshed
            save()
        }
        let started = url.startAccessingSecurityScopedResource()
        let readable = started || FileManager.default.isReadableFile(atPath: url.path)
        guard readable else { return nil }
        openFolders[folder.id] = url
        return url
    }

    private func enqueueScan(_ folder: MusicFolder) {
        let previous = scanQueue
        scanQueue = Task { [weak self] in
            await previous?.value
            await self?.scan(folder)
        }
    }

    private func scan(_ folder: MusicFolder) async {
        guard let root = access(folder) else {
            statusMessage = "“\(folder.name)” needs to be chosen again."
            return
        }
        isScanning = true
        statusMessage = "Scanning \(folder.name)…"
        let files = await Task.detached {
            LibraryStore.audioFiles(in: root)
        }.value

        var scanned: [Track] = []
        scanned.reserveCapacity(files.count)
        for (index, file) in files.enumerated() {
            if Task.isCancelled { break }
            statusMessage = "Scanning \(index + 1) of \(files.count) in \(folder.name)"
            if let track = await Self.readTrack(file: file, folder: folder, root: root) {
                scanned.append(track)
            }
        }

        let previous = tracks.filter { $0.folderID == folder.id }
        let keptArtwork = Set(scanned.compactMap(\.artworkFilename))
        for track in previous where !keptArtwork.contains(track.artworkFilename ?? "") {
            if let artwork = artworkURL(for: track) {
                try? FileManager.default.removeItem(at: artwork)
            }
        }
        tracks.removeAll { $0.folderID == folder.id }
        tracks.append(contentsOf: scanned)
        save()
        isScanning = false
        backfillDatesIfNeeded()
        if scanned.isEmpty {
            statusMessage = "No audio files in \(folder.name)."
        } else {
            statusMessage = "\(scanned.count) tracks from \(folder.name)."
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.libraryFile) else { return }
        guard let snapshot = try? decoder.decode(LibrarySnapshot.self, from: data) else { return }
        folders = snapshot.folders
        tracks = snapshot.tracks.map { track in
            var track = track
            track.title = Self.songTitle(track.title)
            return track
        }
    }

    private func save() {
        let snapshot = LibrarySnapshot(folders: folders, tracks: tracks)
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.libraryFile, options: .atomic)
        NotificationCenter.default.post(name: .musicLibraryDidChange, object: nil)
    }

    #if os(macOS)
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    private static func albumOrder(_ lhs: Track, _ rhs: Track) -> Bool {
        if lhs.trackNumber != rhs.trackNumber {
            return lhs.trackNumber < rhs.trackNumber
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    nonisolated private static func audioFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard AudioFile.extensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    nonisolated private static func readTrack(file: URL, folder: MusicFolder, root: URL) async -> Track? {
        let asset = AVURLAsset(url: file)
        let duration = (try? await asset.load(.duration)).map(\.seconds) ?? 0
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        var title: String?
        var artist: String?
        var album: String?
        var artwork: Data?
        for item in metadata {
            if item.commonKey == .commonKeyTitle {
                title = try? await item.load(.stringValue)
            } else if item.commonKey == .commonKeyArtist {
                artist = try? await item.load(.stringValue)
            } else if item.commonKey == .commonKeyAlbumName {
                album = try? await item.load(.stringValue)
            } else if item.commonKey == .commonKeyArtwork {
                artwork = try? await item.load(.dataValue)
            }
        }
        let allMetadata = (try? await asset.load(.metadata)) ?? []
        var trackNumber = 0
        for item in allMetadata {
            guard item.identifier == .id3MetadataTrackNumber || item.identifier == .iTunesMetadataTrackNumber else {
                continue
            }
            if let text = try? await item.load(.stringValue) {
                trackNumber = parseTrackNumber(text)
            } else if let number = try? await item.load(.numberValue) {
                trackNumber = number.intValue
            }
            if trackNumber > 0 { break }
        }

        let id = UUID()
        var artworkFilename: String?
        if let artwork, !artwork.isEmpty, let stored = storeArtwork(artwork, id: id) {
            artworkFilename = stored
        }

        let filename = file.deletingPathExtension().lastPathComponent
        let parent = file.deletingLastPathComponent().lastPathComponent
        let dates = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return Track(
            id: id,
            folderID: folder.id,
            relativePath: relativePath(of: file, under: root),
            title: songTitle(cleaned(title) ?? filename),
            artist: cleaned(artist) ?? "Unknown Artist",
            album: cleaned(album) ?? parent,
            trackNumber: trackNumber,
            duration: duration.isFinite ? duration : 0,
            artworkFilename: artworkFilename,
            modifiedAt: dates?.contentModificationDate,
            createdAt: dates?.creationDate
        )
    }

    private func backfillDatesIfNeeded() {
        let lookups: [(UUID, URL)] = tracks.compactMap { track in
            guard track.modifiedAt == nil || track.createdAt == nil else { return nil }
            guard let url = url(for: track) else { return nil }
            return (track.id, url)
        }
        guard !lookups.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            var found: [UUID: (Date?, Date?)] = [:]
            found.reserveCapacity(lookups.count)
            for (id, url) in lookups {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                found[id] = (values?.contentModificationDate, values?.creationDate)
            }
            await self?.applyDates(found)
        }
    }

    private func applyDates(_ found: [UUID: (Date?, Date?)]) {
        var changed = false
        for index in tracks.indices {
            guard let dates = found[tracks[index].id] else { continue }
            if tracks[index].modifiedAt == nil, let modified = dates.0 {
                tracks[index].modifiedAt = modified
                changed = true
            }
            if tracks[index].createdAt == nil, let created = dates.1 {
                tracks[index].createdAt = created
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    nonisolated private static func songTitle(_ value: String) -> String {
        var result = ""
        var skippingUnderscores = false
        for character in value {
            if character == "_" {
                skippingUnderscores = true
                continue
            }
            if skippingUnderscores {
                if !result.isEmpty, result.last != " " {
                    result.append(" ")
                }
                skippingUnderscores = false
            }
            result.append(character)
        }
        return result
    }

    nonisolated private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func parseTrackNumber(_ value: String) -> Int {
        let head = value.split(separator: "/").first.map(String.init) ?? value
        return Int(head.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    nonisolated private static func relativePath(of file: URL, under folder: URL) -> String {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let full = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard full.hasPrefix(base) else { return file.lastPathComponent }
        var relative = String(full.dropFirst(base.count))
        while relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative
    }

    nonisolated private static func storeArtwork(_ data: Data, id: UUID) -> String? {
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let filename = "\(id.uuidString).img"
        let destination = artworkDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: destination, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    nonisolated private static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MusicPlayer", isDirectory: true)
    }

    nonisolated private static var libraryFile: URL {
        supportDirectory.appendingPathComponent("library.json")
    }

    nonisolated fileprivate static var artworkDirectory: URL {
        supportDirectory.appendingPathComponent("Artwork", isDirectory: true)
    }
}

private struct LibrarySnapshot: Codable {
    var folders: [MusicFolder]
    var tracks: [Track]
}
