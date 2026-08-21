# Elden Ring Boss Checklist

A native boss kill tracker for Elden Ring, with three ways to get your progress
into OBS. Reads your save file (**read-only**) to work out which bosses you've
beaten — safe to use with EAC.

![The checklist tab](screenshots/checklist.png)

## Features

- Native desktop app on Windows and Linux — no browser needed to use it
- Detects boss kills from your save file (**read-only**), while you play
- Finds your saves for you, including Proton prefixes, Flatpak Steam and
  Seamless Co-op
- Multiple boss lists: all bosses, main story, remembrances, great runes, DLC,
  hardlock
- Reads your death count and character level
- **Attempt counter** — deaths since your last boss kill, reset automatically
  when the next one falls
- **Session totals** — bosses and deaths for this sitting
- **Boss defeated banner** — the overlay names the boss for a few seconds when
  it dies
- Remembers your setup — save file, character, boss list, window size, theme —
  between restarts
- Elden Ring colour theme by default (Dark, Light and follow-the-OS also
  available), with an adjustable text size
- **Three OBS integrations**, use whichever suits you:
  - **Browser source** — the transparent overlay page, the best-looking option
  - **Text files** — plain text files for OBS "Text (GDI+/FreeType)" sources
    set to *Read from file*. Works on any OBS version, no browser source
  - **obs-websocket** — connects to OBS directly and keeps text sources
    updated, the way most OBS tools work. You choose which scene they go in
- Mobile companion page for single-monitor players

## Building

Requires the [Odin compiler](https://odin-lang.org/) (a recent nightly — the
app uses the merged `core:os` API), plus what Skald needs:

- **Vulkan loader and driver** — `libvulkan1` + `mesa-vulkan-drivers` on Linux;
  bundled with any modern GPU driver on Windows
- **SDL3** — `libsdl3-0` on Linux; Odin's `vendor:sdl3` ships `SDL3.dll` on
  Windows

The GUI framework, [Skald](https://github.com/BuLEEto/Skald), is vendored at
`vendor/skald/` — nothing to fetch.

### Linux

```bash
make build      # build ./er-boss-checklist
make run        # build and run
make tar        # release tarball, with libSDL3.so.0 bundled alongside
make deb        # .deb that depends on the distro's libsdl3-0
```

### Windows

From a Developer Command Prompt (MSVC on PATH):

```cmd
odin build . -collection:gui=vendor/skald -o:speed -out:er-boss-checklist.exe
copy "%ODIN_ROOT%\vendor\sdl3\SDL3.dll" .
```

Cross-compiling from Linux doesn't work — SDL3 and Vulkan link through MSVC
import libraries.

See [BUILD.md](BUILD.md) for the full setup, including distros that don't
package SDL3 yet.

## Usage

Run the app. On first launch:

1. **Setup** tab → **Choose save file…**. A picker opens and searches every
   Steam library it can find — including Proton prefixes, Flatpak Steam and
   Seamless Co-op — reads each save, and lists the characters in it. Click a
   character to start tracking it. **Browse…** is there if your save lives
   somewhere unusual.
2. Pick a boss list if you want something other than all bosses.
3. **Checklist** tab shows progress; it updates itself while you play.

Text feeling small? **Setup → Text size**. It scales the whole interface, not
just the type.

The save-file check runs every 5 seconds by default. That's also the floor —
Elden Ring writes its save on its own schedule, so polling faster can't surface
a kill any sooner. Each check is just an mtime comparison; the save is only
re-read when it actually changed.

Everything you choose is saved immediately to your config directory, so the
app comes back the way you left it:

| | |
|---|---|
| Linux | `~/.config/er-boss-checklist/settings.json` |
| Windows | `%APPDATA%\er-boss-checklist\settings.json` |

The **About** tab shows the exact path.

## OBS

All three live on the **OBS** tab, one panel each — **Browser source**, **Text
files**, **obs-websocket** — because each has its own setup on the OBS side and
stacking them down one page made it impossible to tell which controls belonged
to which. They can all run at the same time.

Each panel has a **? How do I use this** button with step-by-step OBS
instructions: which source type to add, where the setting lives, what each
value is.

Each panel is self-contained: **Region** and **Appearance** belong to the
integration, not to the app. The overlay can sit on Caelid in gold while the
text files follow the first unfinished area and the websocket widgets show
Altus Plateau at 64px — which is usually what you want when two of them are on
screen at once, since you'd rarely show the same thing twice.

### Browser source (best looking)

Leave *Run the web server* on, pick your overlay mode (summary / next up /
region) and background, then copy the URL into an OBS **Browser Source**. The
page updates live over server-sent events — no refresh interval to tune.

**Region** decides which area this integration shows. Each of the three has its
own, set on its own panel:

| | |
|---|---|
| *Auto — where I last killed* | Tracks the area your most recent kill happened in, so it follows you around. The save records only *that* a boss is dead, never when — so this counts kills the app was open for. Falls back to first-unfinished until it's seen one, and again once that area is cleared. |
| *Auto — first unfinished* | The first area with anything left, in list order. |
| A region by name | Pinned. Everything stays there until you change it. |

A pin puts `&region=N` in the copied overlay URL so the browser source agrees.
The automatic modes deliberately leave it off — the server then resolves the area
on every request, so the page keeps following instead of freezing on whichever
area was current when you copied the URL. The pin is stored by name, so
switching boss lists can't silently repoint it at a different area.

**Align** switches the whole overlay between left and right. Worth knowing why
it lives here and not on the text sources: OBS's own text sources have no text
alignment and no line-height control, so a multi-line list is stuck left-aligned
whatever you do with the scene item's bounding box — that only moves the block,
not the lines inside it. The overlay is a web page, so alignment is one CSS
rule.

Keep the background **Transparent** for a browser source.

### Recolouring the overlay

The page's colours are CSS custom properties, so OBS's **Custom CSS** box (in
the browser source's properties) repaints the whole thing:

```css
:root { --gold: #ff4444; --text: #ffffff; }
```

The variables are `--gold`, `--gold-dim`, `--text`, `--text-dim`, `--red` and
`--green`. The app never writes to that box, and never resends the source's
width or height after creating it, so your styling and sizing survive. The green and magenta
options exist for people capturing the page as a window instead, where a
transparent background isn't possible and you need a chroma key.

### Attempts, sessions and the kill banner

**Attempts** is the number of deaths since the last boss you killed, and it
resets itself the moment the next one falls. Elden Ring doesn't record deaths
per boss anywhere in the save, so that is exactly what it counts — a death
exploring, to a fall, or to an invader lands in it too. It's the number souls
streamers usually mean by "attempt 38", but it's an inference, not a per-boss
stat. There's a **Reset attempts** button on the Checklist tab.

**Session** is bosses and deaths for this sitting. It starts again each time you
open the app, and has its own reset.

Both are bookmarked per character, so switching character doesn't subtract one
Tarnished's deaths from another's.

**Boss defeated banner** announces the boss by name on the overlay browser
source for a few seconds, then goes back to the numbers. It sits at the bottom
of the source, so leave that source some height below the card or the two will
overlap. It uses the Browser source panel's accent and text colours, and can be
turned off.

Everything here comes from the save file, and the game only writes that every so
often — so expect a kill to show up within about ten seconds of the fight
ending, not the instant the boss falls.

### Text files

Turn on *Write text files* and point OBS **Text (GDI+)** / **Text (FreeType 2)**
sources at them with *Read from file* ticked. No browser source, no extra CPU,
works on every OBS version:

| File | Contents |
|---|---|
| `progress.txt` | `113 / 207 bosses` |
| `killed.txt` / `total.txt` / `remaining.txt` | just the number |
| `percent.txt` | `54%` |
| `deaths.txt` | death count |
| `attempts.txt` | deaths since your last boss kill |
| `session.txt` | `2 bosses · 31 deaths` for this sitting |
| `character.txt` | `Moo Moo Ruka — RL 113` |
| `next_boss.txt` | the next boss still standing |
| `next_bosses.txt` | the next few, one per line |
| `region.txt` | first unfinished region and its count |
| `region_bosses.txt` | what's left in that region, one per line |
| `regions.txt` | every region and its count, one per line |

### obs-websocket

Enable OBS's own WebSocket server (**Tools → WebSocket Server Settings**), then
enter the host, port and password on the OBS tab and hit **Connect**.

**Add to scene** decides where the sources are created, and picking one is
required: until you do, the app connects and creates nothing. Defaulting to
whichever scene happened to be live would put eight sources in your *Starting
Soon* scene, and you'd find out on stream. Your scenes are listed once you've
connected.

Changing it reconnects and adds the sources to the new scene; the copies in the
old scene are left alone, so delete those in OBS if you don't want them. A scene
you've since renamed or deleted is treated as "not chosen" — nothing is created,
and sources that already exist keep updating, because the app addresses those by
name and doesn't care which scene they're in.

The app creates a text source per ticked entry — `ER Progress`, `ER Next Boss`,
`ER Deaths`, `ER Attempts`, `ER Session`, `ER Character`, `ER Region` and
`ER Region Bosses` — with a bold white font and a dark outline, stacked down the
left so they don't land on top of each other. `ER Region` and `ER Region Bosses`
give you the same per-area breakdown as the overlay's Region mode.

Restyle and position them in OBS however you like: the app only ever changes
their text, and a source that already exists is never created, moved or
restyled.

**Source style** decides what the individual sources are made of:

| | |
|---|---|
| **Text** | OBS text sources. Cheap — no browser instance — but OBS gives them no text alignment and no line height, so a multi-line list is stuck ragged-left. |
| **Web** | Each value becomes its own small browser source pointed at `/widget`. Real CSS: alignment and line height work, and each source has its own Custom CSS box. Costs a browser instance per source. |

Either way they're separate sources, so you position each one independently.

**ER Overlay** is the odd one out in both styles: a browser source showing the
whole overlay card in one box. Off by default, since it overlaps the individual
sources.

**Send to OBS** on the same tab picks which of them you want.

#### Appearance

**Appearance** styles the pages this app serves — accent colour, text colour,
size, font family, outline, alignment, plus an **Advanced — custom CSS** box
for anything else. There are two, one per panel: the overlay card has its own
on **Browser source**, and the individual widgets have theirs on
**obs-websocket** (visible when Source style is Web), so the two can look
different.

**Font** lists the families installed on this PC (via fontconfig on Linux, GDI
on Windows), filtered as you type. It's also free-form: OBS is what renders the
page, so if OBS runs on a different machine, type the font name as it's spelled
*there* — this list is a convenience, not a restriction. The first entry clears
the setting and leaves the page on its own font stack.

It lives in the app rather than being left to OBS for a specific reason: OBS's
Custom CSS box belongs to a *single source*. With eight sources, theming
through OBS means pasting the same rules eight times, and again on every tweak.
The app serves the pages, so one change repaints all of that panel's.

OBS's box still works, and still wins — it's injected after ours — which makes
it the right place for a one-off override on one source:

```css
:root { --gold: #ff4444; --text: #ffffff; }   /* colours */
.widget-value, .widget-line { font-size: 40px; line-height: 1.6; }
```

Alignment can be set three ways, narrowest wins:

1. **Align** on the OBS tab — sets every source at once
2. That source's **URL** — change `align=right` to `left` or `center`
3. That source's **Custom CSS** — `body { text-align: center !important }`

The `!important` is needed for the third because the app's rule is a class
selector and outranks a bare `body`. Unticking one
*hides* it in OBS rather than deleting it — anything you've styled or positioned
survives, and re-ticking brings it straight back. OBS has no undo for a deleted
source, so hiding is the safer default; delete it yourself if you want it gone.

OBS text sources have no line-height setting in either flavour — it's been a
[standing feature request](https://ideas.obsproject.com/posts/1285/text-source-line-height-option)
for years. **Blank line between entries** is the only lever there is: it sends
an extra newline between items in the multi-line sources and text files.

The password is only written to `settings.json` if you tick *Remember the
password*, and it's encrypted first — AES-256-GCM under a key derived from a
per-machine identifier (`/etc/machine-id` on Linux, the registry's `MachineGuid`
on Windows). A config file copied to another machine, synced to a cloud drive
or pasted into a bug report is inert. It is *not* protection from something
already running as you; that needs the OS keychain.

### Mobile companion

Handy on a single monitor: open the mobile URL from the OBS tab on your phone.

### While you play

Minimising the window doesn't stop any of it. The web server, the save polling,
the text files and the obs-websocket pushes all keep running — only the drawing
stops. The window idles at 0 fps and repaints solely when something changes, so
leaving it open costs you effectively nothing.

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
| `main.odin` | Startup: load data, settings, server, hand off to the GUI |
| `gui.odin` | GUI state, messages, update — the only writer of shared state |
| `gui_view.odin` | GUI layout for all four tabs |
| `app_state.odin` | Shared state and its threading contract |
| `settings.odin` | Config-directory settings, with migration from older builds |
| `server.odin` | Web server for the OBS overlay and mobile page |
| `obs_text.odin` | Text-file output for OBS text sources |
| `obs_ws.odin` | obs-websocket v5 client |
| `save_parser.odin` | Elden Ring save file parser (sequential binary format) |
| `save_scan.odin` | Steam library / Proton prefix save discovery |
| `theme.odin` | Elden Ring palette and the text-size scale |
| `gui_help.odin` | In-app help sheets for the three OBS integrations |
| `src/libs/sbcrypto/` | AES-256-GCM at-rest encryption for the saved password |
| `boss_data.odin` | Boss list loading and filtering |
| `platform_*.odin` | LAN IP detection, per platform |
| `src/libs/http/` | HTTP server library |
| `src/libs/websocket/` | Minimal RFC 6455 client, for obs-websocket |
| `vendor/skald/` | Skald GUI framework (vendored, zlib) |
| `bosses.json` | Boss definitions with event flag IDs |
| `hardlock.json` | Hard-lock boss progression data |
| `eventflag_bst.txt` | Event flag BST lookup table |
| `templates/`, `static/` | Overlay and mobile pages |

The parser was built by cross-referencing three independent format
implementations.

See [THIRD_PARTY.md](THIRD_PARTY.md) for full credits and licenses.

## Safety

This application **never writes to your save file**. It opens the file in read-only mode to check event flags. It should not trigger any anti-cheat detection.

## Disclaimer

- Elden Ring Boss Kill Tracker is provided "as is" without warranty of any kind, express or implied.
- We are not liable for any loss of data, emotional distress, or damages arising from the use of this application.
Liability
- To the fullest extent permitted by law, the developer shall not be liable for any indirect, incidental, special, consequential, or punitive damages arising from your use of Elden Ring Boss Kill Tracker is provided.
- This includes but is not limited to loss of data, loss of profits, or damages resulting from its use.
Changes
- These terms may be updated at any time. Continued use of the application constitutes acceptance of any changes.

## License

MIT
