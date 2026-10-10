import SwiftUI

#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
#endif

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedSidebarID: String?
    @State private var focusedTrackID: UUID?
    @State private var query = ""
    @State private var searchPresented = false
    @State private var selectedSearchIndex = 0
    #if os(macOS)
    @StateObject private var searchKeys = LibrarySearchKeys()
    #endif
    @State private var didOpenRestoredFolder = false
    @State private var showPlayer = false
    @State private var showFolderPicker = false
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    #if os(iOS)
    @State private var sidebarBeforeSearch: String?
    #endif

    var body: some View {
        Group {
            if app.library.folders.isEmpty && app.library.tracks.isEmpty && !app.library.isScanning {
                WelcomeView(chooseFolder: chooseFolder)
            } else {
                libraryShell
            }
        }
        .sheet(isPresented: $showPlayer) {
            NowPlayingView()
                .environmentObject(app)
        }
        #if os(iOS)
        .background {
            FolderPickerPresenter(isPresented: $showFolderPicker) { urls in
                app.library.add(urls: urls)
            }
        }
        #endif
    }

    private var libraryShell: some View {
        VStack(spacing: 0) {
            folderBrowser
            if app.player.currentTrack != nil {
                MiniPlayer(showPlayer: $showPlayer, onSearch: focusSearch)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            guard !didOpenRestoredFolder else { return }
            didOpenRestoredFolder = true
            if let track = app.player.currentTrack {
                showFolder(for: track)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .musicPlayerFocusSearch)) { _ in
            focusSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .musicPlayerShowNowPlaying)) { _ in
            showPlayer = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .musicPlayerRevealTrack)) { note in
            guard let id = note.object as? UUID,
                  let track = app.library.tracks.first(where: { $0.id == id }) else { return }
            showFolder(for: track)
        }
    }

    private var folderBrowser: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selectedSidebarID) {
                ForEach(sidebarFolders) { item in
                    sidebarFolderRow(item)
                        .tag(item.id as String?)
                }
                Section {
                    Button(action: chooseFolder) {
                        Label("Add Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        app.library.rescanAll()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(app.library.isScanning)
                    if !app.library.statusMessage.isEmpty {
                        Text(app.library.statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Library")
            #if os(iOS)
            .searchable(text: $query, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
            .searchSuggestions {
                if isSearching {
                    ForEach(matchingSongs) { track in
                        Button(track.title) {
                            playFromSearch(track)
                        }
                    }
                }
            }
            .onChange(of: searchPresented) { _, presented in
                guard !presented, let previous = sidebarBeforeSearch else { return }
                sidebarBeforeSearch = nil
                selectedSidebarID = previous
            }
            #else
            .searchable(text: $query, isPresented: $searchPresented, placement: .toolbar, prompt: "Songs, artists, albums")
            #endif
            .onChange(of: query) { _, _ in
                selectedSearchIndex = 0
            }
            #if os(macOS)
            .onChange(of: isSearching) { _, searching in
                if searching {
                    searchKeys.start()
                } else {
                    searchKeys.stop()
                }
            }
            .onDisappear {
                searchKeys.stop()
            }
            .background {
                LibrarySearchKeySync(keys: searchKeys, results: matchingSongs, index: $selectedSearchIndex, play: playFromSearch)
                SearchResultsDropdown(
                    isSearching: isSearching,
                    selection: selectedSearchIndex,
                    resultCount: matchingSongs.count,
                    panel: AnyView(searchResultPanel)
                )
            }
            #endif
        } detail: {
            NavigationStack {
                if let item = selectedSidebarFolder {
                    FolderContents(folder: item.libraryFolder, relativePath: item.path, query: "", focusTrackID: focusedTrackID, songsOnly: true) { _ in }
                } else {
                    ContentUnavailableView("Choose a folder", systemImage: "folder", description: Text("Folders in your library appear on the left."))
                }
            }
        }
        #if os(macOS)
        .toolbarBackground(.visible, for: .windowToolbar)
        #endif
    }

    private func playFromSearch(_ track: Track) {
        #if os(iOS)
        sidebarBeforeSearch = nil
        #endif
        app.playSongInItsFolder(track)
        query = ""
        searchPresented = false
        showFolder(for: track)
    }

    private func showFolder(for track: Track) {
        let parent = (track.relativePath as NSString).deletingLastPathComponent
        focusedTrackID = track.id
        selectedSidebarID = SidebarFolder.id(folderID: track.folderID, path: parent)
    }

    private var sidebarFolders: [SidebarFolder] {
        var items: [SidebarFolder] = []
        for libraryFolder in app.library.folders {
            let paths = Set(app.library.tracks.filter { $0.folderID == libraryFolder.id }.map {
                ($0.relativePath as NSString).deletingLastPathComponent
            })
            for path in paths {
                let name = path.isEmpty ? libraryFolder.name : (path as NSString).lastPathComponent
                items.append(SidebarFolder(libraryFolder: libraryFolder, path: path, name: name))
            }
        }
        let counts = Dictionary(grouping: items, by: \.name).mapValues(\.count)
        return items
            .map { item in
                var item = item
                    if counts[item.name, default: 0] > 1, !item.path.isEmpty {
                    let parent = (item.path as NSString).deletingLastPathComponent
                    let parentName = parent.isEmpty
                        ? item.libraryFolder.name
                        : (parent as NSString).lastPathComponent
                    if !parentName.isEmpty {
                        item.name = "\(parentName) / \(item.name)"
                    }
                }
                return item
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedSidebarFolder: SidebarFolder? {
        sidebarFolders.first { $0.id == selectedSidebarID }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var matchingSongs: [Track] {
        Array(LibrarySearch.ranked(app.library.tracks, query: query) { [$0.title, $0.artist, $0.album] }.prefix(10))
    }

    private var searchResultPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            if matchingSongs.isEmpty {
                Text("No results")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(matchingSongs.enumerated()), id: \.element.id) { index, track in
                    Button {
                        selectedSearchIndex = index
                        playFromSearch(track)
                    } label: {
                        Text(track.title)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(index == selectedSearchIndex ? Color.accentColor.opacity(0.22) : Color.clear)
                    )
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        }
    }

    private func sidebarFolderRow(_ item: SidebarFolder) -> some View {
        let count = app.library.tracks.filter {
            $0.folderID == item.libraryFolder.id && ($0.relativePath as NSString).deletingLastPathComponent == item.path
        }.count
        return HStack {
            Label(item.name, systemImage: "folder")
            Spacer(minLength: 8)
            Text("\(count)")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func focusSearch() {
        #if os(iOS)
        if sizeClass == .compact {
            if sidebarBeforeSearch == nil {
                sidebarBeforeSearch = selectedSidebarID
            }
            selectedSidebarID = nil
        }
        columnVisibility = .all
        searchPresented = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            searchPresented = true
            activateSearchField()
        }
        #else
        searchPresented = true
        #endif
    }

    #if os(iOS)
    private func activateSearchField() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            if let field = searchField(in: window) {
                field.becomeFirstResponder()
                return
            }
        }
    }

    private func searchField(in view: UIView) -> UISearchBar? {
        if let field = view as? UISearchBar { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }
    #endif

    private func chooseFolder() {
        #if os(macOS)
        app.library.pickFolders()
        #else
        showFolderPicker = true
        #endif
    }
}

private struct SidebarFolder: Identifiable, Hashable {
    var libraryFolder: MusicFolder
    var path: String
    var name: String

    var id: String { Self.id(folderID: libraryFolder.id, path: path) }

    static func id(folderID: UUID, path: String) -> String {
        folderID.uuidString + "\n" + path
    }
}

private struct WelcomeView: View {
    var chooseFolder: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Play music from a folder")
                .font(.title2.bold())
            Text("Choose a folder on this \(deviceName). Music Player indexes the audio files there and plays them on iPhone and Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Choose Music Folder", action: chooseFolder)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("MP3, M4A, AAC, ALAC, FLAC, WAV, AIFF")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }
}

private struct FolderContents: View {
    @EnvironmentObject private var app: AppModel
    var folder: MusicFolder
    var relativePath: String
    var query: String
    var focusTrackID: UUID?
    var songsOnly = false
    var open: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if (!songsOnly && childFolders.isEmpty && directTracks.isEmpty) || (songsOnly && directTracks.isEmpty) {
                    ContentUnavailableView(
                        "Nothing here",
                        systemImage: "folder",
                        description: Text(app.library.isScanning ? app.library.statusMessage : "This folder has no audio files.")
                    )
                } else {
                    if !songsOnly && !childFolders.isEmpty {
                        Section("Folders") {
                            ForEach(childFolders) { child in
                                Button {
                                    open(child.path)
                                } label: {
                                    HStack {
                                        Label(child.name, systemImage: "folder")
                                            .foregroundStyle(.primary)
                                        Spacer(minLength: 8)
                                        Text("\(trackCount(under: child.path))")
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !directTracks.isEmpty {
                        Section("Songs") {
                            ForEach(directTracks) { track in
                                TrackRow(track: track, tracks: directTracks)
                                    .id(track.id)
                            }
                        }
                    }
                }
            }
            .onAppear {
                scrollToFocusedTrack(with: proxy)
            }
            .onChange(of: focusTrackID) { _, _ in
                scrollToFocusedTrack(with: proxy)
            }
        }
        .navigationTitle(songsOnly ? songListTitle : breadcrumb)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    app.songSortOrder = app.songSortOrder.toggled
                } label: {
                    Image(systemName: app.songSortOrder.symbol)
                }
                .accessibilityLabel(app.songSortOrder.label)
                Menu {
                    ForEach(SongSort.allCases) { option in
                        Button {
                            app.songSort = option
                        } label: {
                            if app.songSort == option {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .accessibilityLabel("Sort by \(app.songSort.title)")
            }
        }
    }

    private func scrollToFocusedTrack(with proxy: ScrollViewProxy) {
        guard let focusTrackID, directTracks.contains(where: { $0.id == focusTrackID }) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(focusTrackID, anchor: .center)
        }
    }

    private var songListTitle: String {
        relativePath.isEmpty ? folder.name : (relativePath as NSString).lastPathComponent
    }

    private var breadcrumb: String {
        var parts = [folder.name]
        if !relativePath.isEmpty {
            parts.append(contentsOf: relativePath.split(separator: "/").map(String.init))
        }
        return parts.joined(separator: " › ")
    }

    private var folderTracks: [Track] {
        app.library.tracks.filter { $0.folderID == folder.id }
    }

    private var childFolders: [FolderGroup] {
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        var names = Set<String>()
        for track in folderTracks {
            let parent = (track.relativePath as NSString).deletingLastPathComponent
            guard parent.hasPrefix(prefix) else { continue }
            let rest = String(parent.dropFirst(prefix.count))
            guard let name = rest.split(separator: "/").first else { continue }
            names.insert(String(name))
        }
        let groups = names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.map { name in
            FolderGroup(path: relativePath.isEmpty ? name : prefix + name)
        }
        return LibrarySearch.ranked(groups, query: query) { group in
            [group.name] + tracks(under: group.path).flatMap { [$0.title, $0.artist, $0.album] }
        }
    }

    private var directTracks: [Track] {
        let songs = folderTracks
            .filter { ($0.relativePath as NSString).deletingLastPathComponent == relativePath }
        let ordered = sortedSongs(songs, by: app.songSort, order: app.songSortOrder)
        return LibrarySearch.ranked(ordered, query: query) { [$0.title, $0.artist, $0.album] }
    }

    private func tracks(under path: String) -> [Track] {
        let prefix = path.isEmpty ? "" : path + "/"
        return folderTracks.filter { track in
            let parent = (track.relativePath as NSString).deletingLastPathComponent
            return parent == path || parent.hasPrefix(prefix)
        }
    }

    private func trackCount(under path: String) -> Int {
        tracks(under: path).count
    }
}

private struct TrackRow: View {
    @EnvironmentObject private var app: AppModel
    var track: Track
    var tracks: [Track]
    var onPlay: (() -> Void)? = nil

    var body: some View {
        Button {
            if let onPlay {
                onPlay()
            } else {
                app.player.play(tracks: tracks, startingAt: track)
            }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(track: track, side: 44)
                ContinuingTitle(
                    title: track.title,
                    primary: isCurrent ? Color.accentColor : Color.primary
                )
                Spacer(minLength: 8)
                Text(formatTime(track.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var isCurrent: Bool {
        app.player.currentTrack?.id == track.id
    }
}

private struct ContinuingTitle: View {
    var title: String
    var primary: Color
    @State private var width: CGFloat = 0

    var body: some View {
        let lines = TitleSplit.lines(title, width: width)
        VStack(alignment: .leading, spacing: 2) {
            Text(lines.head)
                .foregroundStyle(primary)
                .lineLimit(1)
            if !lines.tail.isEmpty {
                Text(lines.tail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: TitleWidthKey.self, value: geo.size.width)
            }
        }
        .onPreferenceChange(TitleWidthKey.self) { newWidth in
            if abs(newWidth - width) > 0.5 {
                width = newWidth
            }
        }
    }
}

private struct TitleWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum TitleSplit {
    static func lines(_ title: String, width: CGFloat) -> (head: String, tail: String) {
        guard width > 8 else { return (title, "") }
        let font = bodyFont()
        if textWidth(title, font: font) <= width {
            return (title, "")
        }
        let characters = Array(title)
        var low = 1
        var high = characters.count
        var fit = 1
        while low <= high {
            let mid = (low + high) / 2
            let prefix = String(characters.prefix(mid))
            if textWidth(prefix, font: font) <= width {
                fit = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        if fit < characters.count {
            let slice = characters[..<fit]
            if let space = slice.lastIndex(of: " "), space > fit / 3 {
                fit = space
            }
        }
        let head = String(characters.prefix(fit)).trimmingCharacters(in: .whitespaces)
        let tail = String(characters.dropFirst(fit)).trimmingCharacters(in: .whitespaces)
        return (head, tail)
    }

    #if os(iOS)
    private static func bodyFont() -> UIFont {
        UIFont.preferredFont(forTextStyle: .body)
    }

    private static func textWidth(_ text: String, font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
    #else
    private static func bodyFont() -> NSFont {
        NSFont.preferredFont(forTextStyle: .body)
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
    #endif
}

struct MiniPlayer: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var showPlayer: Bool
    var onSearch: () -> Void
    var onOpenPlayer: (() -> Void)? = nil
    var reservesHomeArea = true
    var usesSystemIcons = false
    var onShowFolder: (() -> Void)? = nil

    private var cardColor: Color {
        colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.90)
    }

    var body: some View {
        if let track = app.player.currentTrack {
            VStack(spacing: 8) {
                Group {
                    if usesSystemIcons {
                        TickerTitle(text: track.title, running: app.player.isPlaying)
                    } else {
                        #if os(iOS)
                        TickerTitle(text: track.title, running: app.player.isPlaying, font: .headline, lineHeight: 26)
                        #else
                        Text(track.title)
                            .font(.headline)
                            .lineLimit(1)
                        #endif
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenPlayer?()
                }
                SeekBar(barHeight: 36)
                    .padding(.horizontal, 8)
                HStack(spacing: usesSystemIcons ? 0 : 20) {
                    if usesSystemIcons {
                        barButton("magnifyingglass", label: "Search", expands: true) {
                            onSearch()
                        }
                    }
                    #if os(iOS)
                    if !usesSystemIcons {
                        barButton("magnifyingglass", label: "Search", expands: false) {
                            onSearch()
                        }
                    }
                    #endif
                    barButton("backward.fill", label: "Previous", expands: usesSystemIcons) {
                        app.player.previous()
                    }
                    Button {
                        app.player.toggle()
                    } label: {
                        Image(systemName: app.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: usesSystemIcons ? 48 : 44))
                            .frame(maxWidth: usesSystemIcons ? .infinity : nil, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(app.player.isPlaying ? "Pause" : "Play")
                    barButton("forward.fill", label: "Next", expands: usesSystemIcons) {
                        app.player.next()
                    }
                    #if os(iOS)
                    if !usesSystemIcons {
                        barButton(app.player.repeatMode.symbol, label: app.player.repeatMode.label, active: app.player.repeatMode != .off, expands: false) {
                            app.player.cycleRepeat()
                        }
                    }
                    #endif
                    if usesSystemIcons {
                        barButton("folder", label: "Folder", expands: true) {
                            onShowFolder?()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .modifier(HomeAreaPadding(enabled: reservesHomeArea))
            .background {
                if reservesHomeArea {
                    Rectangle()
                        .fill(cardColor)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .padding(.horizontal, reservesHomeArea ? 0 : 10)
            .padding(.top, reservesHomeArea ? 0 : 10)
            .padding(.bottom, reservesHomeArea ? 0 : 10)
        }
    }

    private func barButton(_ symbol: String, label: String, active: Bool = false, expands: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(maxWidth: expands ? .infinity : nil, minHeight: 52)
                .frame(minWidth: expands ? nil : 52)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

private struct TickerTitle: View {
    var text: String
    var running: Bool
    var font: Font = .system(size: 15)
    var lineHeight: CGFloat = 22
    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var timer: Timer?

    var body: some View {
        GeometryReader { geo in
            let scrolls = textWidth > geo.size.width
            HStack(spacing: spacing) {
                title
                if scrolls {
                    title
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: scrolls ? offset : 0)
            .frame(maxHeight: .infinity, alignment: .leading)
            .onAppear {
                containerWidth = geo.size.width
                syncTimer()
            }
            .onChange(of: geo.size.width) { _, width in
                containerWidth = width
                syncTimer()
            }
            .onChange(of: text) { _, _ in
                offset = 0
            }
            .onChange(of: textWidth) { _, _ in
                syncTimer()
            }
            .onChange(of: running) { _, _ in
                syncTimer()
            }
            .onDisappear { stopTimer() }
        }
        .frame(height: lineHeight)
        .clipped()
    }

    private var spacing: CGFloat { 40 }

    private var title: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { textWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in
                            textWidth = width
                        }
                }
            }
    }

    private func syncTimer() {
        stopTimer()
        let travel = textWidth + spacing
        guard running, textWidth > containerWidth, travel > 0 else { return }
        let timer = Timer(timeInterval: 1.0 / 40, repeats: true) { _ in
            Task { @MainActor in
                offset -= 0.7
                if offset <= -travel {
                    offset += travel
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

private struct HomeAreaPadding: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.safeAreaPadding(.bottom)
        } else {
            content
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let track = app.player.currentTrack {
                    ArtworkView(track: track, side: 280)
                        .shadow(radius: 16, y: 8)
                    VStack(spacing: 4) {
                        Text(track.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(track.artist)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(track.album)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 16)
                    VStack(spacing: 6) {
                        SeekBar()
                        HStack {
                            Text(formatTime(app.player.currentTime))
                            Spacer()
                            Text(formatTime(app.player.duration))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 28) {
                        control("shuffle", active: app.player.shuffle, label: "Shuffle") {
                            app.player.toggleShuffle()
                        }
                        control("backward.fill", label: "Previous") {
                            app.player.previous()
                        }
                        Button {
                            app.player.toggle()
                        } label: {
                            Image(systemName: app.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 64))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(app.player.isPlaying ? "Pause" : "Play")
                        control("forward.fill", label: "Next") {
                            app.player.next()
                        }
                        control(app.player.repeatMode.symbol, active: app.player.repeatMode != .off, label: app.player.repeatMode.label) {
                            app.player.cycleRepeat()
                        }
                    }
                } else {
                    ContentUnavailableView("Nothing playing", systemImage: "music.note")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Now Playing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 680)
        #endif
    }

    private func control(_ symbol: String, active: Bool = false, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct SeekBar: View {
    @EnvironmentObject private var app: AppModel
    var barHeight: CGFloat = 44
    var trackColor = Color.secondary.opacity(0.35)

    var body: some View {
        GeometryReader { geo in
            let duration = max(app.player.duration, 0.1)
            let fraction = min(max(app.player.currentTime / duration, 0), 1)
            let thumbX = geo.size.width * fraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(height: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: thumbX, height: 4)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 16, height: 16)
                    .offset(x: thumbX - 8)
            }
            .transaction { transaction in
                transaction.animation = nil
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let time = time(at: value.location.x, width: geo.size.width, duration: duration)
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            app.player.isScrubbing = true
                            app.player.currentTime = time
                        }
                    }
                    .onEnded { value in
                        let time = time(at: value.location.x, width: geo.size.width, duration: duration)
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            app.player.seek(to: time)
                        }
                    }
            )
        }
        .frame(height: barHeight)
        .accessibilityLabel("Playback position")
        .accessibilityValue(formatTime(app.player.currentTime))
    }

    private func time(at x: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        let clamped = min(max(x, 0), max(width, 1))
        return duration * (clamped / max(width, 1))
    }
}

private struct ArtworkView: View {
    @EnvironmentObject private var app: AppModel
    var track: Track
    var side: CGFloat

    var body: some View {
        Group {
            if let image = app.player.artworkImage(for: track) {
                #if os(macOS)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                #else
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                #endif
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.32))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side > 80 ? 16 : 8, style: .continuous))
    }
}

#if os(iOS)
private struct FolderPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard isPresented, controller.presentedViewController == nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        context.coordinator.parent = self
        controller.present(picker, animated: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: FolderPickerPresenter

        init(parent: FolderPickerPresenter) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.isPresented = false
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}
#endif

#if os(macOS)
private struct LibrarySearchKeySync: View {
    var keys: LibrarySearchKeys
    var results: [Track]
    var index: Binding<Int>
    var play: (Track) -> Void

    var body: some View {
        Color.clear
            .onAppear { apply() }
            .onChange(of: results.map(\.id)) { _, _ in apply() }
            .onChange(of: index.wrappedValue) { _, _ in apply() }
    }

    private func apply() {
        keys.results = results
        keys.play = play
        keys.index = index
        if index.wrappedValue >= results.count {
            index.wrappedValue = max(results.count - 1, 0)
        }
    }
}

private struct SearchResultsDropdown: NSViewRepresentable {
    var isSearching: Bool
    var selection: Int
    var resultCount: Int
    var panel: AnyView

    func makeNSView(context: Context) -> DropdownAnchor {
        let view = DropdownAnchor(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: DropdownAnchor, context: Context) {
        context.coordinator.sync(anchor: nsView, isSearching: isSearching, resultCount: resultCount, panel: panel)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class DropdownAnchor: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.present()
        }
    }

    final class Coordinator {
        private var hosting: NSHostingView<AnyView>?
        private var panelWindow: NSPanel?
        private var resizeToken: NSObjectProtocol?
        private weak var anchor: NSView?
        private var isSearching = false
        private var resultCount = 0
        private var panelView = AnyView(EmptyView())

        func sync(anchor: NSView, isSearching: Bool, resultCount: Int, panel: AnyView) {
            self.anchor = anchor
            self.isSearching = isSearching
            self.resultCount = resultCount
            self.panelView = panel
            present()
        }

        func present() {
            guard let anchor, let window = anchor.window else { return }
            guard isSearching else {
                hide()
                return
            }
            let host = hosting ?? NSHostingView(rootView: panelView)
            host.rootView = panelView
            hosting = host
            let popup = panelWindow ?? makePanel()
            popup.contentView = host
            panelWindow = popup
            if popup.parent !== window {
                popup.parent?.removeChildWindow(popup)
                window.addChildWindow(popup, ordered: .above)
            }
            if resizeToken == nil {
                resizeToken = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.place(in: window)
                }
            }
            place(in: window)
            popup.orderFront(nil)
        }

        private func makePanel() -> NSPanel {
            let popup = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 50),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            popup.isFloatingPanel = true
            popup.level = .popUpMenu
            popup.hasShadow = true
            popup.backgroundColor = .clear
            popup.isOpaque = false
            popup.hidesOnDeactivate = false
            popup.becomesKeyOnlyIfNeeded = true
            popup.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            return popup
        }

        private func hide() {
            guard let popup = panelWindow else { return }
            popup.orderOut(nil)
            popup.parent?.removeChildWindow(popup)
        }

        private func place(in window: NSWindow) {
            guard let popup = panelWindow else { return }
            let height = CGFloat(max(resultCount, 1)) * 34 + 16
            let width: CGFloat
            let origin: NSPoint
            if let field = searchField(in: window), field.bounds.width > 20, field.bounds.height > 8 {
                let onScreen = window.convertToScreen(field.convert(field.bounds, to: nil))
                width = onScreen.width
                origin = NSPoint(x: onScreen.minX, y: onScreen.minY - height - 4)
            } else {
                width = 280
                let content = window.convertToScreen(window.contentLayoutRect)
                origin = NSPoint(x: content.maxX - width - 8, y: content.maxY - height)
            }
            popup.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        }

        private func searchField(in window: NSWindow) -> NSView? {
            var roots: [NSView] = []
            if let root = window.contentView?.superview { roots.append(root) }
            for accessory in window.titlebarAccessoryViewControllers {
                roots.append(accessory.view)
            }
            for root in roots {
                if let field = findSearchField(in: root, searchOnly: true) { return field }
            }
            for root in roots {
                if let field = findSearchField(in: root, searchOnly: false) { return field }
            }
            return nil
        }

        private func findSearchField(in view: NSView, searchOnly: Bool) -> NSView? {
            if view is NSSearchField, view.frame.width > 40 { return view }
            if !searchOnly, let field = view as? NSTextField, field.isEditable, field.frame.width > 80 { return field }
            for subview in view.subviews {
                if let field = findSearchField(in: subview, searchOnly: searchOnly) { return field }
            }
            return nil
        }
    }
}

private final class LibrarySearchKeys: ObservableObject {
    var results: [Track] = []
    var play: ((Track) -> Void)?
    var index: Binding<Int>?
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard !results.isEmpty, let index else { return event }
        guard let window = NSApp.keyWindow, window.canBecomeMain,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return event }
        switch event.keyCode {
        case 125:
            index.wrappedValue = min(index.wrappedValue + 1, results.count - 1)
            return nil
        case 126:
            index.wrappedValue = max(index.wrappedValue - 1, 0)
            return nil
        case 36, 76:
            guard results.indices.contains(index.wrappedValue) else { return event }
            let track = results[index.wrappedValue]
            let play = play
            DispatchQueue.main.async {
                play?(track)
            }
            return nil
        default:
            return event
        }
    }
}
#endif
