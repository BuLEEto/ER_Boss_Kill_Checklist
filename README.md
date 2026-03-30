# Elden Ring Boss Checklist

A real-time boss kill tracker for Elden Ring with OBS overlay support. Reads your save file in **read-only mode** to track which bosses you've defeated — safe to use with EAC.

## Features

- Automatically detects boss kills from your save file (read-only, never writes)
- Multiple boss lists: all bosses, main story, remembrance, DLC
- Death counter per character
- OBS-compatible transparent overlay
- Mobile-friendly companion page
- Multi-slot support (up to 10 characters)
- Works on Linux and Windows

## Building

Requires the [Odin compiler](https://odin-lang.org/) (latest build dev-2026-03 recommended).

### Linux

```bash
make build
```

This produces a statically-linked `er-boss-checklist` binary.

To build and run:

```bash
make run
```

### Windows

```cmd
odin build . -out:er-boss-checklist.exe
```

## Usage

```bash
./er-boss-checklist
```

Open `http://localhost:3000` in your browser. Use the settings panel to configure your save file path and active character slot.

### OBS Overlay

Add a Browser Source in OBS pointing to `http://localhost:3000/overlay`. The overlay has a transparent background and updates in real-time.

### Save File Locations

**Windows:**

```
%AppData%\EldenRing\<steam_id>\ER0000.sl2
```

**Linux (Steam/Proton):**
```
~/.steam/steam/steamapps/compatdata/1245620/pfx/drive_c/users/steamuser/AppData/Roaming/EldenRing/<steam_id>/ER0000.sl2
```

For Seamless Co-op, the file is `ER0000.co2` under the mod's app ID instead of `1245620`.

## Source Code Overview

| File | Purpose |
|------|---------|
| `main.odin` | HTTP server, routes, SSE events, settings management |
| `save_parser.odin` | Elden Ring save file parser (sequential binary format parsing) |
| `boss_data.odin` | Boss list loading and filtering |
| `platform_linux.odin` | Linux-specific LAN IP detection |
| `platform_windows.odin` | Windows-specific LAN IP detection |
| `bosses.json` | Boss definitions with event flag IDs |
| `hardlock.json` | Hard-lock boss progression data |
| `eventflag_bst.txt` | Event flag BST lookup table |
| `templates/` | HTML templates (main page, overlay, mobile) |
| `static/` | CSS and JavaScript |

## How It Works

The save parser walks through the binary save format sequentially — parsing each section header and variable-length data to locate the event flags region. Boss kills are stored as individual bits in the event flags, checked against known flag IDs from `bosses.json`.

The parser was built by cross-referencing three independent format implementations. See [THIRD_PARTY.md](THIRD_PARTY.md) for full credits and licenses.

## Safety

This application **never writes to your save file**. It opens the file in read-only mode to check event flags. It will not trigger any anti-cheat detection.

## License

MIT
