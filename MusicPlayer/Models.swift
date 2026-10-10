import Foundation

enum AudioFile {
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif"]
}

struct MusicFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var bookmarkData: Data
}

struct Track: Identifiable, Codable, Hashable {
    var id: UUID
    var folderID: UUID
    var relativePath: String
    var title: String
    var artist: String
    var album: String
    var trackNumber: Int
    var duration: TimeInterval
    var artworkFilename: String?
    var modifiedAt: Date?
    var createdAt: Date?
}

enum SongSort: String, CaseIterable, Identifiable {
    case alphabetical
    case modified
    case created

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphabetical: return "Alphabetically"
        case .modified: return "Date modified"
        case .created: return "Date Created"
        }
    }
}

enum SongSortOrder: String {
    case ascending
    case descending

    var toggled: SongSortOrder {
        self == .ascending ? .descending : .ascending
    }

    var symbol: String {
        self == .ascending ? "arrow.up" : "arrow.down"
    }

    var label: String {
        self == .ascending ? "Sort ascending" : "Sort descending"
    }
}

func sortedSongs(_ tracks: [Track], by sort: SongSort, order: SongSortOrder) -> [Track] {
    tracks.sorted { lhs, rhs in
        if sort != .alphabetical {
            let left = sort == .modified ? lhs.modifiedAt : lhs.createdAt
            let right = sort == .modified ? rhs.modifiedAt : rhs.createdAt
            switch (left, right) {
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return order == .ascending ? leftDate < rightDate : leftDate > rightDate
            default:
                break
            }
        }
        let comparison = songSortComparison(lhs, rhs, sort: sort)
        if comparison == .orderedSame { return false }
        let ascending = comparison == .orderedAscending
        return order == .ascending ? ascending : !ascending
    }
}

private func songSortComparison(_ lhs: Track, _ rhs: Track, sort: SongSort) -> ComparisonResult {
    switch sort {
    case .alphabetical:
        let title = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if title != .orderedSame { return title }
        return lhs.relativePath.localizedStandardCompare(rhs.relativePath)
    case .modified:
        return dateComparison(lhs.modifiedAt, rhs.modifiedAt, tie: lhs, rhs)
    case .created:
        return dateComparison(lhs.createdAt, rhs.createdAt, tie: lhs, rhs)
    }
}

private func dateComparison(_ lhs: Date?, _ rhs: Date?, tie: Track, _ other: Track) -> ComparisonResult {
    switch (lhs, rhs) {
    case let (left?, right?):
        if left != right { return left < right ? .orderedAscending : .orderedDescending }
    case (nil, nil):
        break
    case (nil, _?):
        return .orderedDescending
    case (_?, nil):
        return .orderedAscending
    }
    let title = tie.title.localizedCaseInsensitiveCompare(other.title)
    if title != .orderedSame { return title }
    return tie.relativePath.localizedStandardCompare(other.relativePath)
}

struct AlbumGroup: Identifiable, Hashable {
    var artist: String
    var title: String

    var id: String { artist + "\n" + title }
}

struct FolderGroup: Identifiable, Hashable {
    var path: String

    var id: String { path }
    var name: String {
        path.isEmpty ? "Library" : (path as NSString).lastPathComponent
    }
}

enum RepeatMode: String, Codable, CaseIterable {
    case off
    case one
    case all

    var next: RepeatMode {
        switch self {
        case .off: return .one
        case .one: return .all
        case .all: return .off
        }
    }

    var symbol: String {
        switch self {
        case .off: return "repeat"
        case .one: return "repeat.1"
        case .all: return "repeat"
        }
    }

    var label: String {
        switch self {
        case .off: return "Repeat off"
        case .one: return "Repeat one"
        case .all: return "Repeat all"
        }
    }
}

extension Notification.Name {
    static let musicLibraryDidChange = Notification.Name("MusicPlayer.libraryDidChange")
    static let musicPlayerFocusSearch = Notification.Name("MusicPlayer.focusSearch")
    static let musicPlayerShowNowPlaying = Notification.Name("MusicPlayer.showNowPlaying")
    static let musicPlayerRevealTrack = Notification.Name("MusicPlayer.revealTrack")
}

enum LibrarySearch {
    static func words(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Keeps items that match at least one word. Items that match more words come first.
    static func ranked<T>(_ items: [T], query: String, fields: (T) -> [String]) -> [T] {
        let words = words(in: query)
        guard !words.isEmpty else { return items }
        return items
            .map { item in (item, matchCount(in: fields(item), words: words)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private static func matchCount(in fields: [String], words: [String]) -> Int {
        words.reduce(0) { count, word in
            let matched = fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            return count + (matched ? 1 : 0)
        }
    }
}

func formatTime(_ time: TimeInterval) -> String {
    guard time.isFinite, time > 0 else { return "0:00" }
    let total = Int(time.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}
