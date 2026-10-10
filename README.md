# Music Player

Music Player is an offline player for audio files already on your iPhone, iPad, or Mac. You choose one or more folders, the app indexes the audio inside them, and playback stays on the device. Files are not copied into the app and nothing is streamed.

| | |
| --- | --- |
| Platforms | iOS 17 and later (iPhone and iPad), macOS 15 and later |
| Language | Swift 5, SwiftUI |
| Version | 1.0.0 |
| Bundle ID | `com.mujassir.musicplayer` |
| License | [Apache License 2.0](LICENSE) |

## What it does

### Library

- Add one or more folders. Nested folders are scanned automatically.
- Hidden files and package contents are skipped.
- Supported extensions: **MP3, M4A, AAC, ALAC, FLAC, WAV, AIFF, AIF**.
- Metadata is read with AVFoundation: title, artist, album, track number, duration, and embedded artwork.
- A missing title falls back to the file name. Underscores in titles are shown as spaces.
- A missing artist is labeled **Unknown Artist**. A missing album uses the parent folder name.
- The sidebar lists each folder that contains songs, with a song count. When two folders share a name, the parent folder is shown as well (`Parent / Name`).
- **Add Folder** and **Rescan** are in the sidebar. On Mac, the same actions are in the File menu: **Choose Music Folder…** (⌘O) and **Rescan Folders** (⌘R).
- Adding a folder that is already in the library is ignored.
- Removing a folder drops its tracks and stored artwork.
- If a previously chosen folder can no longer be opened, the status line asks you to choose it again.

The first launch with an empty library shows a welcome screen and a **Choose Music Folder** button.

### Browsing and search

- Selecting a folder shows its songs. Each row has artwork (or a note icon), the title, and the duration. Long titles continue on a second line.
- The current song is highlighted.
- Sort from the toolbar by **Alphabetically**, **Date modified**, or **Date Created**, and flip ascending or descending. The choice is remembered. The default is date modified, newest first.
- Search matches songs, artists, and albums. Each word in the query can match any of those fields, and results that match more words come first. The list shows up to 10 songs.
- Choosing a result plays that song and jumps the library to its folder.
- On Mac, search results appear in a dropdown under the toolbar field. Arrow keys move the selection and Return plays it.
- On iPhone and iPad, results appear as search suggestions. The mini player has a search button that opens the field.

### Playback

Tapping a song plays it and queues the other songs in the same folder, in the current sort order.

- **Play / pause**, **next**, and **previous**.
- Previous restarts the current song when more than 3 seconds have played. Otherwise it goes to the previous song. At the start of the queue it restarts the song, or wraps to the end when repeat-all is on.
- Drag the seek bar to scrub.
- **Shuffle** randomizes the upcoming queue and keeps the current song first.
- **Repeat** cycles through off, repeat one, and repeat all.
  - Repeat one restarts the current song when it ends.
  - Repeat all continues through the queue and wraps to the start.
  - Repeat off plays the next song if there is one, then pauses.
- When a song ends with repeat off and more songs remain, the next song starts.
- The queue, position, shuffle, and repeat mode are saved. On Mac, the app resumes and keeps playing. On iPhone and iPad, it restores the song paused at the saved position.
- The mini player sits at the bottom while something is playing. Its title scrolls while audio is playing.
- **Now Playing** shows large artwork, title, artist, album, the seek bar with elapsed and remaining time, and shuffle, previous, play/pause, next, and repeat.

### iPhone and iPad

- Folders are chosen with the system document picker. Several folders can be added at once.
- Audio continues in the background and with the screen locked (`audio` background mode).
- Lock Screen and Control Center show the title, artist, album, artwork, and playback position, and accept play, pause, next, previous, and scrubbing.

### Mac

- The app is sandboxed. It can read only the folders you choose, and it keeps security-scoped bookmarks so those folders stay available after relaunch.
- It opens as a menu bar app (a music-note icon) and does not show the library window on launch. It stays running after the last window closes. Clicking the Dock icon opens the library.
- On first launch it registers itself as a login item so the menu bar player is available after you sign in.
- The menu bar panel shows the current song, a seek bar, search, previous, play/pause, next, and the songs in the current folder. Search there uses the same ranking and keyboard controls as the library. Clicking the title opens the library window.
- Playback menu shortcuts: Space to play or pause, ⌘→ next, ⌘← previous.
- The library window opens at 1100×740.

## Setup

### Requirements

- A Mac with **Xcode 16** or later.
- For the Mac app: **macOS 15** or later.
- For the iOS app: an iPhone or iPad on **iOS 17** or later, or an iOS 17+ simulator.
- A free Apple ID is enough to run on the simulator and on your own Mac. A paid Apple Developer account is required to install on a device you do not develop with day to day, or to distribute the app.

No third-party packages are used.

### Open and run

1. Clone the repository and open `MusicPlayer.xcodeproj` in Xcode.
2. Select the **MusicPlayer** scheme for iPhone and iPad, or **MusicPlayerMac** for Mac.
3. Choose a run destination: a simulator, a connected device, or **My Mac**.
4. Open the target’s **Signing & Capabilities** tab and set your Team. Signing is automatic.
5. If the bundle identifier `com.mujassir.musicplayer` is already taken by another team, change `PRODUCT_BUNDLE_IDENTIFIER` for that target (or the `bundleIdPrefix` / target settings in `project.yml`, then regenerate).
6. Press **Run**.

On a physical iPhone or iPad, trust the developer certificate in **Settings → General → VPN & Device Management** if iOS asks.

### First launch

1. Tap **Choose Music Folder** (or use **File → Choose Music Folder…** on Mac).
2. Pick a folder that contains audio files. You can add more later with **Add Folder**.
3. Wait for the scan status in the sidebar. When it finishes, folders appear on the left and songs on the right.
4. Tap a song to play it.

If you add files to a folder later, use **Rescan**.

### Regenerate the Xcode project

`project.yml` is the source of the project. The checked-in `MusicPlayer.xcodeproj` is generated from it. After you change targets, deployment versions, entitlements, or the bundle identifier in `project.yml`:

```bash
brew install xcodegen
xcodegen generate
```

Run that from the repository root. It rewrites `MusicPlayer.xcodeproj`.

## Project layout

```
project.yml                  XcodeGen spec (targets, signing, schemes)
MusicPlayer.xcodeproj        Generated Xcode project
Config/
  iOS-Info.plist             Background audio mode
  iOS.entitlements
  macOS.entitlements         App Sandbox, read-only user-selected files, app-scoped bookmarks
MusicPlayer/
  MusicPlayerApp.swift       App entry, Mac menu bar, menus, login item
  AppModel.swift             Shared library and player, sort preference
  LibraryStore.swift         Folder bookmarks, scanning, metadata, persistence
  PlayerController.swift     AVPlayer queue, shuffle, repeat, resume, remote commands
  Models.swift               Track model, sort, search ranking
  RootView.swift             Library, mini player, now playing, search
  Assets.xcassets            App icon
```

## Where data is stored

Audio files stay in the folders you chose. The app writes only its own index:

| Data | Location |
| --- | --- |
| Folder bookmarks and track index | `~/Library/Application Support/MusicPlayer/library.json` |
| Extracted artwork | `~/Library/Application Support/MusicPlayer/Artwork/` |
| Sort order and resume position | `UserDefaults` (`MusicPlayer.songSort`, `MusicPlayer.songSortOrder`, `MusicPlayer.Resume`) |

On iOS those paths are inside the app container. Deleting the app removes the index and artwork. It does not delete your music folders.

## Notes

- Playback uses the file at its original path. If you move or rename a file, rescan or choose the folder again.
- macOS only reads folders you pick. It does not scan the disk on its own.
- The Mac app does not publish Now Playing info to the system. Lock Screen and Control Center metadata are implemented on iOS.
- The Mac menu bar player can list and play the folder of the current song, and can search the whole library.
