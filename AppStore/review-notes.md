# App Review notes (reply to Guideline 2.1 information request)

Paste everything between the lines into App Store Connect → iOS App 1.0.0 → App Review Information → Notes.

---

1. SCREEN RECORDING
Attached in the App Review attachments: recorded on a physical iPhone 17 Pro running the latest iOS. It starts from the Home Screen, launches Cassette, adds a music folder, plays songs, uses search and Now Playing, then goes to the Home Screen to show playback continuing in the background and being controlled from the Lock Screen view and Control Center. (iOS stops screen recordings when the device is locked, so the Lock Screen controls are shown by swiping down from the top-left.) Cassette has no accounts, no user-generated content and no paid content.

2. PURPOSE AND TARGET AUDIENCE
Cassette is an offline music player for people who already own music files (for example ripped CDs, purchased downloads or their own recordings) and want to play them on iPhone or iPad without streaming, a subscription, an account or an internet connection, such as on flights, while travelling or with poor signal. The user picks one or more folders in the Files app; Cassette indexes the audio inside (MP3, M4A, AAC, ALAC, FLAC, WAV, AIFF) and plays it with background audio and Lock Screen controls. Files are never copied or uploaded.

3. SETUP AND MAIN FEATURES
No login or account is needed.
a) Sample files: download https://github.com/mujassir/ios-music-player/raw/main/AppStore/review-sample-music.zip on the device, open it in the Files app to unzip, and move the "Music" folder to On My iPhone (any MP3 or M4A files also work).
b) Open Cassette and tap "Choose Music Folder", browse to the "Music" folder and tap Open.
c) The library lists each folder with its song count. Tap a folder, then tap a song to play it; the rest of the folder is queued.
d) Mini player at the bottom: Back (to the folder list), Previous, Play/Pause, Next, Search. Search matches song titles, artists and albums.
e) Tap the song title in the mini player to open Now Playing: artwork, seek bar, shuffle and repeat.
f) Lock the device: audio keeps playing and can be controlled from the Lock Screen and Control Center.

4. EXTERNAL SERVICES
None. Cassette makes no network requests and includes no third-party SDKs, analytics, advertising, authentication, payment or AI services. Everything runs on the device using Apple frameworks (SwiftUI, AVFoundation, MediaPlayer).

5. REGIONAL DIFFERENCES
None. The app works the same in every region where it is available.

6. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
Not applicable. Cassette ships with no music or other third-party content and plays only files the user already has on the device. The sample files linked above are synthesized test tones with fictional titles, made for this review.

---
