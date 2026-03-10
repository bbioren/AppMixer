# AppMixer

Per-app volume mixer for macOS, living in your menu bar.

macOS doesn't let you control volume per app. AppMixer fixes that by tapping into individual audio streams using CoreAudio's process tap API (macOS 14.2+).

## Features

- **Per-app volume control** - individual sliders for every app outputting audio (0-200%)
- **Master volume** - global multiplier across all apps
- **Mute toggles** - per-app and master mute buttons
- **Persistent settings** - volume levels and mute states saved across restarts
- **Auto-discovery** - new audio sources appear automatically within seconds
- **Menu bar native** - lightweight popover UI, no dock icon

## Requirements

- macOS 14.2 (Sonoma) or later
- Screen capture permission (required for audio taps)

## Install

### Homebrew

```bash
brew install --cask bbioren/tap/appmixer
```

### Download

Grab the latest `.dmg` from [GitHub Releases](https://github.com/bbioren/AppMixer/releases), open it, and drag AppMixer to Applications.

### Build from source

```bash
git clone https://github.com/bbioren/AppMixer.git
cd AppMixer
./scripts/build-release.sh
open dist/AppMixer.app
```

## Usage

1. Launch AppMixer - a slider icon appears in your menu bar
2. Click it to open the mixer popover
3. Adjust individual app volumes or the master slider
4. Right-click the icon for reset/quit options

On first launch, macOS will prompt for screen capture permission. This is required for audio tapping to work.

## How it works

AppMixer uses the CoreAudio `CATapDescription` API introduced in macOS 14.2 to create per-process audio taps. Each tap intercepts an app's audio output through a private aggregate device, applies a gain multiplier in an IO proc callback, and forwards it to your output device. The app polls for new audio-outputting processes every 3 seconds.

## License

MIT
