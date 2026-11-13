# Isle

A small macOS app that turns the notch at the top of your screen into a handy little island. Hover over the notch (or press <kbd>⌃ Space</kbd>) to open it.

## Features

- **Home** — a motivational quote that changes every 5 minutes, what's playing (Spotify, Apple Music, Safari, YouTube and more) with playback controls, and CPU / GPU usage, temperature and memory pressure.
- **Activity circles** — keep awake, a timer, downloads in progress and your next meeting each get a small circle beside the notch, so the notch itself keeps your music. Click a circle to open it.
- **Notifications in the notch** — banners from any app (Messages, WhatsApp, Mail…) appear in the notch. Optional; turn it on in Settings.
- **Calendar** — today's events.
- **Timer** — quick countdowns with a progress ring.
- **Clipboard** — text clipboard history (skips password managers).
- **Shelf** — drop files on the island to hold them for later, or convert images to PDF, JPG, HEIC or PNG.
- **Notes** — a quick scratchpad.
- **Camera** — a mirror to check how you look before a call.
- **Keep awake** — stop your Mac from sleeping while the cup icon is on.

## Requirements

- macOS 14 or later
- A Mac with a notch works best; on other Macs the island sits at the top of the screen.
- Temperatures need Apple Silicon.

## Install

### Download

Get `Isle.app` from the [Releases](../../releases) page and move it to `/Applications`.

The app isn't notarized by Apple yet, so the first time you open it macOS will say it can't check it. Right-click Isle → **Open**, or go to **System Settings → Privacy & Security** and click **Open Anyway**.

### Build it yourself

Needs Xcode or the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/yabeshlimbu17/isle.git
cd isle
./build.sh install    # builds, copies to /Applications and launches
```

`./build.sh` on its own just builds into `build/Isle.app`.

## Permissions

Isle asks for these only when you use the feature that needs them:

| Permission | Used for |
|---|---|
| Calendars | Showing today's events |
| Camera | The camera mirror |
| Accessibility | Notifications in the notch (only if you turn it on) |
| Downloads folder | Download progress circle |
| Automation (Music, Spotify) | Extra now-playing details and controls for those two apps |

## Things to know

- **Now playing** and **temperatures** use private macOS interfaces (`MediaRemote` and the HID thermal sensors). Apple doesn't document them, so a future macOS update could break them. If that happens Isle hides the missing info instead of crashing. This is also why Isle isn't on the Mac App Store.
- Temperatures show the **hottest** sensor, so they can read higher than apps that show an average. To see every sensor, run `swift tools/sensors.swift`.
- Nothing leaves your Mac except the request for quotes to ZenQuotes.

## Credits

Some quotes are provided by [ZenQuotes API](https://zenquotes.io/).

## License

[MIT](LICENSE)
