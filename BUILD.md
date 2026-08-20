# Build Instructions

## Prerequisites

### Everyone

- [Odin](https://odin-lang.org/docs/install/) on PATH. Use a recent nightly —
  the app uses the merged `core:os` API (`os.user_config_dir`,
  `os.get_executable_directory`, `os.read_all_directory_by_path`), which older
  releases don't have.
- A **Vulkan loader and driver**. Skald renders through Vulkan 1.3.
- **SDL3**. Skald's only C dependency: windowing, input, clipboard, native file
  dialogs, HiDPI.

[Skald](https://github.com/BuLEEto/Skald) itself is vendored at
`vendor/skald/` and imported as `gui:skald` — there's nothing to clone or
fetch. See `vendor/skald/VENDORED.md` for the pinned commit and how to update
it.

### Linux

```bash
sudo apt install libsdl3-0 libvulkan1 mesa-vulkan-drivers   # Debian 13+, Devuan
```

Arch: `sdl3 vulkan-icd-loader`. Fedora 40+: `SDL3 vulkan-loader`.

**Ubuntu 24.04 LTS and Debian 12 have no SDL3 package.** Either build SDL3 from
source (SDL's `docs/README-linux.md` has the dependency list; `release-3.2.10`
matches what stable distros ship), or just use the release tarball — `make tar`
bundles `libSDL3.so.0` next to the binary precisely so those users don't have
to.

Odin ships `vendor:stb` as C source, and Skald loads PNGs through
`stb_image`, so the static archives have to be built once per machine after
installing Odin:

```bash
make -C "$(dirname "$(command -v odin)")/vendor/stb/src"
```

Skip it and an otherwise-clean compile ends in a link error about
`stb_image`. (Windows and macOS Odin installs ship these prebuilt.)

Check the Vulkan side with `vulkaninfo | head`. If that prints device info,
you're set.

### Windows

1. Odin on PATH.
2. Visual Studio Build Tools (MSVC + Windows SDK). Build from the **x64 Native
   Tools Command Prompt** or a Developer PowerShell, so `cl.exe` and the SDK
   libraries are on PATH.
3. Vulkan loader — ships with any recent AMD / NVIDIA / Intel driver. If
   `vulkaninfo` fails, install the [LunarG Vulkan SDK](https://vulkan.lunarg.com/).

`SDL3.dll` comes with Odin at `%ODIN_ROOT%\vendor\sdl3\` — copy it next to the
`.exe`.

## Linux

```bash
make build      # ./er-boss-checklist
make run        # build and run
make debug      # -debug build; F12 opens Skald's widget inspector
make tar        # er-boss-checklist_<version>_linux.tar.gz, SDL3 bundled
make deb        # .deb depending on libsdl3-0 and libvulkan1
make install    # into /opt/er-boss-checklist (needs root)
make clean
```

`make build` links with `RUNPATH=$ORIGIN`, so a `libSDL3.so.0` sitting next to
the binary wins over the system one. That's what makes the tarball portable; in
a dev tree, where no such file exists, the loader just falls through to
`/usr/lib` as normal. No `patchelf` needed.

## Windows

```cmd
odin build . -collection:gui=vendor/skald -o:speed -out:er-boss-checklist.exe
copy "%ODIN_ROOT%\vendor\sdl3\SDL3.dll" .
```

For a release zip, ship:

```
er-boss-checklist.exe
SDL3.dll
bosses.json
hardlock.json
eventflag_bst.txt
templates\
static\
```

Cross-compiling Windows binaries from Linux does **not** work — SDL3 and Vulkan
link through MSVC import libraries, so Windows builds have to happen on
Windows. `make windows` exists for running under Windows with make available;
otherwise use the `odin build` line above.

## What ships, and what doesn't

`bosses.json`, `hardlock.json`, `eventflag_bst.txt`, `templates/` and `static/`
are read at runtime relative to the executable, so they travel with it. The app
chdirs to its own directory at startup, which means launching from a menu entry
or a symlink works.

`settings.json` deliberately does **not** ship next to the binary. It lives in
the user's config directory (`~/.config/er-boss-checklist/` or
`%APPDATA%\er-boss-checklist\`), so an install under `/opt` or `Program Files`
can still save settings. Older versions wrote it beside the executable and
silently failed to persist anything when that directory wasn't writable; the
app migrates such a file on first run.

## Troubleshooting

**"Could not load eventflag_bst.txt"** — the data files aren't next to the
binary. Check the list above.

**Window doesn't open / Vulkan errors** — no Vulkan driver. `vulkaninfo | head`
on Linux; update GPU drivers on Windows.

**`cannot open shared object file: libSDL3.so.0`** — install your distro's SDL3
package, or use the release tarball, which bundles it.

**Link error mentioning `stb_image`** — Odin's stb archives haven't been
built on this machine. See the Linux prerequisites above; it's a one-off
`make -C $ODIN_ROOT/vendor/stb/src`. The same applies to `stb_truetype` if you
opt into the legacy text backend with `-define:SKALD_RUNA=false`.
