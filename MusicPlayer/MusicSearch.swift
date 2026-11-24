#if os(iOS)
import Foundation

/// Turns a spoken request ("Road Trip", artist "Nova Lane", …) into a queue to play.
/// Shared by the App Intents (Siri, Shortcuts, Spotlight) and SiriKit's INPlayMediaIntent.
@MainActor
enum MusicSearch {
    enum Kind { case song, folder, album, artist, library }

    struct Match {
        var kind: Kind
        var title: String
        var tracks: [Track]
        var start: Track
    }

    /// - Parameters:
    ///   - name: the song, folder, album or artist name Siri heard (may be nil).
    ///   - artist / album: extra constraints Siri parsed out of the request.
    ///   - kind: what the user asked for, when Siri knows ("play the album …").
    static func find(name: String?, artist: String?, album: String?, kind: Kind?, in app: AppModel) -> Match? {
        let library = app.library
        guard !library.tracks.isEmpty else { return nil }

        var pool = library.tracks
        if let artist = nonEmpty(artist) {
            let byArtist = best(pool.map { ($0, $0.artist) }, matching: artist, keepAll: true)
            if !byArtist.isEmpty { pool = byArtist }
        }

        let name = nonEmpty(name)
        if let album = nonEmpty(album) ?? (kind == .album ? name : nil) {
            return albumMatch(album, in: pool)
        }
        if kind == .artist, let name {
            return artistMatch(name, in: pool)
        }
        guard let name else {
            // Only an artist ("play Nova Lane") or nothing at all ("play Cassette").
            if nonEmpty(artist) != nil, pool.count < library.tracks.count {
                return artistQueue(pool)
            }
            return libraryMatch(library.tracks)
        }

        switch kind {
        case .song: return songMatch(name, in: pool, app: app)
        case .folder: return folderMatch(name, app: app)
        case .album, .artist, .library, nil: break
        }

        // Unknown type: take whichever kind matches best (song > folder > album > artist on ties).
        let candidates: [(Double, () -> Match?)] = [
            (score(pool.map(\.title), name), { songMatch(name, in: pool, app: app) }),
            (score(PlayableFolder.all(in: library).map(\.name), name), { folderMatch(name, app: app) }),
            (score(pool.map(\.album), name), { albumMatch(name, in: pool) }),
            (score(pool.map(\.artist), name), { artistMatch(name, in: pool) })
        ]
        guard let top = candidates.max(by: { $0.0 < $1.0 }), top.0 > 0 else { return nil }
        return candidates.first { $0.0 == top.0 }?.1()
    }

    static func play(_ match: Match, shuffle: Bool? = nil, in app: AppModel) {
        if let shuffle {
            app.player.shuffle = shuffle
        } else if match.kind == .library {
            app.player.shuffle = true
        }
        app.player.play(tracks: match.tracks, startingAt: match.start)
    }

    // MARK: - Kinds

    static func songMatch(_ name: String, in pool: [Track], app: AppModel) -> Match? {
        guard let track = best(pool.map { ($0, $0.title) }, matching: name).first else { return nil }
        return songQueue(track, app: app)
    }

    static func songQueue(_ track: Track, app: AppModel) -> Match {
        let parent = (track.relativePath as NSString).deletingLastPathComponent
        let siblings = app.library.tracks.filter {
            $0.folderID == track.folderID && ($0.relativePath as NSString).deletingLastPathComponent == parent
        }
        let ordered = sortedSongs(siblings.isEmpty ? [track] : siblings, by: app.songSort, order: app.songSortOrder)
        return Match(kind: .song, title: track.title, tracks: ordered, start: track)
    }

    static func folderMatch(_ name: String, app: AppModel) -> Match? {
        let folders = PlayableFolder.all(in: app.library)
        guard let folder = best(folders.map { ($0, $0.name) }, matching: name).first else { return nil }
        return folderQueue(folder, app: app)
    }

    static func folderQueue(_ folder: PlayableFolder, app: AppModel) -> Match? {
        let ordered = sortedSongs(folder.tracks, by: app.songSort, order: app.songSortOrder)
        guard let first = ordered.first else { return nil }
        return Match(kind: .folder, title: folder.name, tracks: ordered, start: first)
    }

    private static func albumMatch(_ name: String, in pool: [Track]) -> Match? {
        let albums = Dictionary(grouping: pool) { $0.album }
        guard let title = best(albums.keys.map { ($0, $0) }, matching: name).first,
              let tracks = albums[title] else { return nil }
        let ordered = tracks.sorted {
            $0.trackNumber != $1.trackNumber
                ? $0.trackNumber < $1.trackNumber
                : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        guard let first = ordered.first else { return nil }
        return Match(kind: .album, title: title, tracks: ordered, start: first)
    }

    private static func artistMatch(_ name: String, in pool: [Track]) -> Match? {
        let tracks = best(pool.map { ($0, $0.artist) }, matching: name, keepAll: true)
        return artistQueue(tracks)
    }

    private static func artistQueue(_ tracks: [Track]) -> Match? {
        let ordered = tracks.sorted {
            if $0.album != $1.album { return $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
            return $0.trackNumber < $1.trackNumber
        }
        guard let first = ordered.first else { return nil }
        return Match(kind: .artist, title: first.artist, tracks: ordered, start: first)
    }

    static func libraryMatch(_ tracks: [Track]) -> Match? {
        guard let start = tracks.randomElement() else { return nil }
        return Match(kind: .library, title: "All Songs", tracks: tracks, start: start)
    }

    // MARK: - Fuzzy matching

    /// The items whose label best matches `query`. With `keepAll`, every item tied for the best
    /// score is returned (all songs by an artist); otherwise only the single best one.
    private static func best<T>(_ items: [(T, String)], matching query: String, keepAll: Bool = false) -> [T] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        var top = 0.0
        var result: [T] = []
        for (item, label) in items {
            let s = score(normalize(label), q)
            if s > top {
                top = s
                result = [item]
            } else if s == top, s > 0, keepAll || result.isEmpty {
                result.append(item)
            }
        }
        return result
    }

    private static func score(_ labels: [String], _ query: String) -> Double {
        let q = normalize(query)
        return labels.reduce(0) { max($0, score(normalize($1), q)) }
    }

    private static func score(_ label: String, _ query: String) -> Double {
        guard !label.isEmpty, !query.isEmpty else { return 0 }
        if label == query { return 4 }
        if label.hasPrefix(query) || (query.hasPrefix(label) && label.count >= 3) { return 3 }
        if label.contains(query) { return 2 }
        let words = query.split(separator: " ")
        let labelWords = Set(label.split(separator: " "))
        let hits = words.filter { labelWords.contains($0) }.count
        guard hits > 0 else { return 0 }
        return Double(hits) / Double(max(words.count, labelWords.count))
    }

    static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
#endif
