# Vendored: Skald

Upstream: <https://github.com/BuLEEto/Skald>

    Commit:  e0673901ee80dae4811656138da5250bbb6b9c1d
    Date:    2026-08-22 17:26:27 +0100
    Subject: combobox: keep the popover open when it flips above and overlaps the trigger

Licence: zlib — see `LICENSE`. Bundled-asset and third-party
acknowledgements are in `NOTICE`.

## What is here

`skald/` — the framework package, upstream verbatim, imported as
`gui:skald` via `-collection:gui=vendor/skald`.

## What was left out

Nothing the build touches. Omitted to keep the repo light:

| Path | Why |
|---|---|
| `examples/`, `docs/`, `screenshots/` | Not needed to build a consumer app |
| `build.sh`, `build.bat`, `bench.sh` | We have our own `Makefile` |
| `skald/third_party/runa/tools/ucd/*Test.txt` | Unicode conformance test data (~10 MB) — used only by runa's own test suite |
| `skald/third_party/runa/tools/ucd/BidiBrackets.txt`, `DerivedGeneralCategory.txt`, `EastAsianWidth.txt` | Not referenced by any `#load` in the vendored source |

The thirteen UCD files that **are** kept under
`skald/third_party/runa/tools/ucd/` are embedded into the binary at
compile time via `#load` and are required — deleting them breaks the
build with "Cannot address value ... as it has not got a determined
type yet".

## Updating

1. Clone Skald fresh.
2. Replace `skald/`, `LICENSE` and `NOTICE` with the upstream copies.
3. Delete `examples/`, `docs/`, `screenshots/`, the build scripts, and
   the UCD files listed in the table above.
4. Rebuild, then refresh the commit hash at the top of this file.
