# Third Party Credits

## GUI Framework

### Skald

**Source:** [Skald](https://github.com/BuLEEto/Skald) by Lee Fry

**Used for:** the desktop GUI — Elm-architecture widgets, Vulkan renderer,
layout, theming. Vendored at `vendor/skald/`; see
`vendor/skald/VENDORED.md` for the pinned commit and what was trimmed.

**License:** zlib — full text at `vendor/skald/LICENSE`

Skald in turn bundles the following, acknowledged in full at
`vendor/skald/NOTICE`:

- **runa** (Lee Fry + contributors) — pure-Odin OpenType text engine, zlib.
  The default text backend, so this is what our binary ships.
- **Inter** (The Inter Project Authors) — bundled UI typeface, SIL OFL 1.1.
  Embedded into the binary at compile time.
- **Twemoji Mozilla** — colour emoji font, CC-BY 4.0. Embedded into the
  binary at compile time, which makes shipping this app a
  redistribution of the Twemoji artwork. The licence requires the
  attribution line below, which is also shown in the app's About tab:

  > Twemoji by Twitter, Inc. and contributors — CC-BY 4.0

- **Unicode Character Database** — © Unicode, Inc. Property tables that
  runa embeds at compile time; each file keeps its own copyright header
  and pointer to <https://www.unicode.org/terms_of_use.html>.
- **fontstash** (Mikko Mononen), zlib, and **stb** (Sean T. Barrett)
  `stb_truetype` / `stb_image`, MIT / public domain — only reached on
  the legacy `-define:SKALD_RUNA=false` text path, which we do not build.

### SDL3

**Source:** [SDL](https://libsdl.org) by Sam Lantinga and the SDL contributors

**Used for:** windowing, input, clipboard, native file dialogs, HiDPI —
Skald's only C dependency, reached through Odin's `vendor:sdl3` bindings.
Shipped alongside the binary (`libSDL3.so.0` on Linux, `SDL3.dll` on
Windows).

**License:** zlib

### Vulkan

Rendering goes through the Vulkan loader already present on the user's
system (`libvulkan.so.1` / `vulkan-1.dll`, shipped with modern GPU
drivers). Specification by the Khronos Group; nothing from it is
redistributed here.

## Save File Format & Event Flags

The save file parser and event flag BST data used to read boss kill status,
death counts, and character data from Elden Ring save files (.sl2/.co2/.rd2).

Our sequential slot parser is based on the documented save format from these projects:

### er-save-manager (Python)

**Source:** [er-save-manager](https://github.com/Hapfel1/er-save-manager) by Hapfel

**Used for:** eventflag_bst.txt, save format reference (sequential section layout, field sizes, variable-length section parsing)

**License:** MIT

```
MIT License

Copyright (c) 2026 Hapfel

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### ER-Save-Lib (Rust)

**Source:** [ER-Save-Lib](https://github.com/ClayAmore/ER-Save-Lib) by ClayAmore

**Used for:** Save format cross-reference (Gaitem variable-length entries, section ordering, field definitions)

### EldenRingSaveTemplate (010 Editor)

**Source:** [EldenRingSaveTemplate](https://github.com/ClayAmore/EldenRingSaveTemplate) by ClayAmore

**Used for:** Save format cross-reference (binary template field sizes and structure validation)

### Additional Credit

The save format reverse engineering builds on work by:

- **ClayAmore** — Primary save format reverse engineering (ER-Save-Lib, ER-Save-Editor, EldenRingSaveTemplate)
- **The Grand Archives** — [Elden Ring Cheat Table](https://github.com/The-Grand-Archives/Elden-Ring-CT-TGA) (event flag research)
- **Umgak** — Event Flag Manager contributions
- **Souls Modding Community** — [soulsmodding.com](https://soulsmodding.com)
