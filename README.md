# OptHelper

A menu bar app for Macs with a notch. Hover the notch to open a small island with:

- **Now playing** for Spotify, Music, or YouTube (Music) in your browser, on a turntable. Drag the tonearm off the record to pause, back on to play.
- **A shelf**: drop files onto the notch to keep copies there, then drag them out wherever you need them. ⌘V pastes in too.
- **A launcher** (⌥ Space by default): type what you want to open, in plain words, and an AI model works out the links, apps or terminal shortcuts.

## Install

Download `OptHelper.dmg` from the [latest release](https://github.com/Omzee15/opt-helper/releases/latest), open it and drag OptHelper into Applications.

The app isn't notarized by Apple yet, so macOS blocks it the first time. Either:

- open it, close the warning, then go to **System Settings › Privacy & Security** and click **Open Anyway**, or
- run once in Terminal: `xattr -dr com.apple.quarantine /Applications/OptHelper.app`

On first launch OptHelper asks for all the permissions it needs in one go (Accessibility and control of the apps it works with). You can reopen that window from the menu bar icon › **Permissions…**.

The launcher needs an AI model: either the [Claude Code](https://claude.com/claude-code) CLI installed and signed in, or a Gemini API key (menu bar icon › Provider › Gemini).

Requires macOS 13 or later. Runs on Apple Silicon and Intel.

## Build

```sh
./build.sh      # OptHelper.app
./package.sh    # OptHelper.dmg (also notarizes when a Developer ID certificate is set up)
```
