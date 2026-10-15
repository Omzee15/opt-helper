# OptHelper

A menu bar app for Macs with a notch. Hover the notch to open a small island with:

- **Now playing** for the Spotify app, or YouTube Music and the Spotify web player (open.spotify.com) in your browser, on a turntable. Drag the tonearm off the record to pause, back on to play. While music plays, the record keeps spinning beside the closed notch.
- **A music library** (stack button, top left of the island): paste a Spotify or YouTube Music link (in Spotify: Share › Copy link), drag songs and playlists from Spotify onto the notch, or add what's playing. Drag a record onto the turntable to play it in the Spotify app.
- **A shelf**: drop files onto the notch to keep copies there, then drag them out wherever you need them. ⌘V pastes in too.
- **A launcher** (⌥ Space by default): type what you want to open, in plain words, and an AI model works out the links, apps or terminal shortcuts.

## Install

Download `OptHelper.dmg` from the [latest release](https://github.com/Omzee15/opt-helper/releases/latest), open it and drag OptHelper into Applications.

The app isn't notarized by Apple yet, so macOS blocks it the first time. Either:

- open it, close the warning, then go to **System Settings › Privacy & Security** and click **Open Anyway**, or
- run once in Terminal: `xattr -dr com.apple.quarantine /Applications/OptHelper.app`

On first launch OptHelper asks for all the permissions it needs in one go (Accessibility and control of the apps it works with). You can reopen that window from the menu bar icon › **Permissions…**.

The launcher needs an AI model: either the [Claude Code](https://claude.com/claude-code) CLI installed and signed in, or a Gemini API key (menu bar icon › Provider › Gemini).

Spotify works through the Spotify app you have installed, with no account connection or developer app. Without the app, records play in the Spotify web player; reading and controlling a web player needs your browser's "Allow JavaScript from Apple Events" setting turned on.

Requires macOS 13 or later. Runs on Apple Silicon and Intel.

## Build

```sh
./build.sh      # OptHelper.app
./package.sh    # OptHelper.dmg (also notarizes when a Developer ID certificate is set up)
```
