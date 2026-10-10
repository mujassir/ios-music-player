import SwiftUI

#if os(macOS)
import AppKit
import ServiceManagement
#endif

@main
struct MusicPlayerApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        WindowGroup(id: "library") {
            RootView()
                .environmentObject(app)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 740)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Music Folder…") {
                    app.library.pickFolders()
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("Rescan Folders") {
                    app.library.rescanAll()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            CommandMenu("Playback") {
                Button(app.player.isPlaying ? "Pause" : "Play") {
                    app.player.toggle()
                }
                .keyboardShortcut(.space, modifiers: [])
                Button("Next") { app.player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous") { app.player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }
        }
        #endif
        #if os(macOS)
        MenuBarExtra {
            MenuBarPlayer()
                .environmentObject(app)
        } label: {
            DockWindowOpener()
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

#if os(macOS)
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static weak var current: MacAppDelegate?
    var openLibrary: (() -> Void)?
    private var finishedLaunching = false

    override init() {
        super.init()
        MacAppDelegate.current = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let service = SMAppService.mainApp
        if service.status == .notRegistered {
            try? service.register()
        }
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.close()
            }
            self.finishedLaunching = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard finishedLaunching else { return false }
        presentLibrary()
        return false
    }

    func presentLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow(), window.isVisible || window.isMiniaturized {
            orderFront(window)
            return
        }
        openLibrary?()
        for delay in [0.1, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = self.mainWindow() else {
                    self.openLibrary?()
                    return
                }
                self.orderFront(window)
            }
        }
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.canBecomeMain && window.styleMask.contains(.titled)
        }
    }

    private func orderFront(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }
}

private struct DockWindowOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "music.note")
            .onAppear {
                MacAppDelegate.current?.openLibrary = { openWindow(id: "library") }
            }
            .task {
                MacAppDelegate.current?.openLibrary = { openWindow(id: "library") }
            }
    }
}

private struct MenuBarPlayer: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var app: AppModel
    @State private var showPlayer = false
    @State private var searchOpen = false
    @State private var folderOpen = false
    @State private var searchText = ""
    @StateObject private var searchKeys = MenuBarSearchKeys()
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if app.player.currentTrack != nil {
                MiniPlayer(
                    showPlayer: $showPlayer,
                    onSearch: toggleSearch,
                    onOpenPlayer: showExistingLibrary,
                    reservesHomeArea: false,
                    usesSystemIcons: true,
                    onShowFolder: toggleFolder
                )
            } else {
                Text("Nothing playing")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            }
            if searchOpen {
                searchSection
            }
            if folderOpen {
                folderSection
            }
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Songs, artists, albums", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            if !trimmedQuery.isEmpty {
                if searchResults.isEmpty {
                    Text("No results")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, track in
                        Button {
                            searchKeys.selectedIndex = index
                            play(track)
                        } label: {
                            Text(track.title)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(index == searchKeys.selectedIndex ? Color.accentColor.opacity(0.22) : Color.clear)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(SearchKeySync(keys: searchKeys, results: searchResults, play: play))
        .onAppear { focusSearchField() }
        .onDisappear { searchKeys.stop() }
        .onChange(of: searchText) { _, _ in
            searchKeys.selectedIndex = 0
        }
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [Track] {
        Array(LibrarySearch.ranked(app.library.tracks, query: searchText) { [$0.title, $0.artist, $0.album] }.prefix(10))
    }

    private var playingFolderName: String {
        guard let track = app.player.currentTrack else { return "" }
        let parent = (track.relativePath as NSString).deletingLastPathComponent
        if parent.isEmpty {
            return app.library.folders.first { $0.id == track.folderID }?.name ?? "Folder"
        }
        return (parent as NSString).lastPathComponent
    }

    private var folderSongs: [Track] {
        guard let track = app.player.currentTrack else { return [] }
        let parent = (track.relativePath as NSString).deletingLastPathComponent
        let songs = app.library.tracks.filter {
            $0.folderID == track.folderID && ($0.relativePath as NSString).deletingLastPathComponent == parent
        }
        return sortedSongs(songs, by: app.songSort, order: app.songSortOrder)
    }

    private var folderSection: some View {
        let songs = folderSongs
        let rowHeight: CGFloat = 28
        let height = min(CGFloat(max(songs.count, 1)) * rowHeight, 280)
        return VStack(alignment: .leading, spacing: 6) {
            Text(playingFolderName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            songList(songs, rowHeight: rowHeight, height: height)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func songList(_ songs: [Track], rowHeight: CGFloat, height: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if songs.isEmpty {
                    Text("No songs in this folder")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                } else {
                    ForEach(songs) { track in
                        Button {
                            playFolderSong(track)
                        } label: {
                            Text(track.title)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .foregroundStyle(track.id == app.player.currentTrack?.id ? Color.accentColor : Color.primary)
                                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(height: height)
    }

    private func toggleSearch() {
        searchOpen.toggle()
        if searchOpen {
            folderOpen = false
            searchKeys.start()
            focusSearchField()
        } else {
            closeSearch()
        }
    }

    private func toggleFolder() {
        folderOpen.toggle()
        if folderOpen {
            closeSearch()
        }
    }

    private func closeSearch() {
        searchOpen = false
        searchText = ""
        searchFocused = false
        searchKeys.stop()
    }

    private func focusSearchField() {
        searchFocused = true
        DispatchQueue.main.async {
            activateSearchField()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            activateSearchField()
        }
    }

    private func activateSearchField() {
        NSApp.activate()
        for window in NSApp.windows where window.isVisible {
            guard let field = Self.textField(in: window.contentView) else { continue }
            window.makeKey()
            window.makeFirstResponder(field)
            searchFocused = true
            return
        }
    }

    private static func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = textField(in: subview) { return field }
        }
        return nil
    }

    private func play(_ track: Track) {
        app.playSongInItsFolder(track)
        NotificationCenter.default.post(name: .musicPlayerRevealTrack, object: track.id)
        closeSearch()
    }

    private func playFolderSong(_ track: Track) {
        app.playSongInItsFolder(track)
        NotificationCenter.default.post(name: .musicPlayerRevealTrack, object: track.id)
    }

    private func showExistingLibrary() {
        showLibraryWindow(zoom: true)
    }

    private func showLibraryWindow(zoom: Bool = false) {
        MacAppDelegate.current?.openLibrary = { openWindow(id: "library") }
        NSApp.activate()
        if let window = libraryWindow() {
            bringForward(window, zoom: zoom)
        } else {
            openWindow(id: "library")
            DispatchQueue.main.async {
                if let window = libraryWindow() {
                    bringForward(window, zoom: zoom)
                }
            }
        }
    }

    private func libraryWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.canBecomeMain && window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
        }
    }

    private func bringForward(_ window: NSWindow, zoom: Bool) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        if zoom, !window.isZoomed {
            window.zoom(nil)
        }
    }
}

private struct SearchKeySync: View {
    var keys: MenuBarSearchKeys
    var results: [Track]
    var play: (Track) -> Void

    var body: some View {
        Color.clear
            .onAppear { apply() }
            .onChange(of: results.map(\.id)) { _, _ in apply() }
    }

    private func apply() {
        keys.isOpen = true
        keys.results = results
        keys.play = play
        if keys.selectedIndex >= results.count {
            keys.selectedIndex = max(results.count - 1, 0)
        }
    }
}

private final class MenuBarSearchKeys: ObservableObject {
    @Published var selectedIndex = 0
    var isOpen = false
    var results: [Track] = []
    var play: ((Track) -> Void)?
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
        isOpen = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isOpen, !results.isEmpty else { return event }
        switch event.keyCode {
        case 125:
            selectedIndex = min(selectedIndex + 1, results.count - 1)
            return nil
        case 126:
            selectedIndex = max(selectedIndex - 1, 0)
            return nil
        case 36, 76:
            guard results.indices.contains(selectedIndex) else { return event }
            let track = results[selectedIndex]
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
