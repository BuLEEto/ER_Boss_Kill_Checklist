# Third Party Credits

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
