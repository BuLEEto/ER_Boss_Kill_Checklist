# Elden Ring .sl2 Save File Format - Technical Reference

Compiled from reverse engineering by ClayAmore (ER-Save-Lib, EldenRingSaveTemplate),
Hapfel1 (er-save-manager), tremwil (DS3SaveUnpacker), and the Souls modding community.

---

## 1. Overview

The Elden Ring save file (`ER0000.sl2`) is a **BND4 container** holding 12 internal files:
- **USER_DATA_000 through USER_DATA_009**: 10 character save slots
- **USER_DATA_010**: Global data (settings, profile summaries, Steam ID, presets)
- **USER_DATA_011**: Regulation/param data

**CRITICAL: Elden Ring PC saves are NOT encrypted.**
Unlike Dark Souls 3 and Elden Ring: Nightreign, Elden Ring PC saves store
USERDATA entries as plain (unencrypted) data within the BND4 container.
The ER-Save-Lib reads the file directly with no decryption step.
(Nightreign uses AES-128-CBC with key `18 F6 32 66 05 BD 17 8A 55 24 52 3A C0 A0 C6 09`)

---

## 2. BND4 Container Format

### 2.1 Magic Detection

```
Offset 0x00 (4 bytes):
  PC:  "BND4" = 0x424E4434 (little-endian: 0x34444E42)
  PS:  [0xCB, 0x01, 0x9C, 0x2C]
```

### 2.2 BND4 Header (0x40 = 64 bytes)

```
Offset  Size  Field               Value/Notes
------  ----  ------------------  -----------
0x00    4     magic               0x34444E42 ("BND4" LE)
0x04    8     unknown1            0x0001000000000000
0x0C    4     file_count          Number of entries (12 for ER saves)
0x10    8     unknown2            0x0000000000000040
0x18    8     signature           0x3130303030303030 ("00000001" ASCII)
0x20    8     entry_header_size   0x20 (32 bytes per entry header)
0x28    8     data_offset         Offset where file data begins
0x30    1     is_unicode          Boolean: entry names are Unicode
0x31    15    padding             0x200000000000000000000000000000
```

### 2.3 BND4 Entry Header (0x20 = 32 bytes each)

```
Offset  Size  Field               Value/Notes
------  ----  ------------------  -----------
0x00    8     flags/padding       0xFFFFFFFF00000050
0x08    8     entry_size          Size of this entry's data in bytes
0x10    4     data_offset         Absolute offset of entry data in file
0x14    4     name_offset         Absolute offset of entry name string
0x18    8     unused              0x0000000000000000
```

Entry headers appear sequentially after the BND4 header.
Entry names (e.g., "USER_DATA_000") follow, then entry data.

### 2.4 Platform-Specific Section Sizes

```
Section           PC Size      PS Size
--------------    ----------   ----------
Header/preamble   0x2FC        0x6C
UserData 0-9      0x280010 ea  0x280000 ea
UserData 10       0x60010      0x60000
UserData 11       0x240020     0x240010
```

The 0x10 difference (PC vs PS) is the 16-byte MD5 checksum prefix on PC.

---

## 3. USERDATA Entry Structure (Character Slots 0-9)

Each character slot (USER_DATA_000 to USER_DATA_009) is 0x280010 bytes (PC).

### 3.1 Checksum

```
Offset  Size  Field       Notes
------  ----  ----------  -----
0x00    16    checksum    MD5 hash of all bytes from offset 0x10 onward
                          (PC only; PS saves have no checksum prefix)
```

**Checksum algorithm:**
```
checksum = MD5(entry_data[0x10..])
entry_data[0x00..0x10] = checksum
```

### 3.2 Top-Level Character Slot Fields

After the checksum, the slot data contains (in order):
- Version (u32)
- Map ID (4 bytes)
- PlayerGameData structure
- Gaitem (inventory) data
- Event flags
- Horse/Torrent data
- Coordinates
- Network data
- Weather data
- And more...

### 3.3 Event Flags Section

```
Event flags size: 0x1BF99F bytes (1,834,399 bytes)
```

The event flags are a large byte array within each character slot.
The exact offset within the slot depends on preceding variable-size sections.

---

## 4. Event Flag Reading Algorithm

This is the core algorithm for checking boss kill flags:

### 4.1 Constants

```
FLAG_DIVISOR = 1000
BLOCK_SIZE   = 125    (bytes per block)
```

### 4.2 Block-to-Offset Mapping (eventflag_bst.txt)

A lookup table maps "block numbers" to "block offsets". This table is derived
from the game's event flag BST (binary search tree). Format is CSV:
```
block_number,block_offset
```
Example entries: `1045540,6223` etc. There are hundreds of entries.
The file is ~150KB. You MUST have this mapping table.

### 4.3 Flag Check Algorithm

```
function get_event_flag(event_flags: []u8, event_id: u32) -> bool:
    // Step 1: Determine which block this flag belongs to
    block = event_id / 1000           // integer division

    // Step 2: Get position within the block
    index = event_id - (block * 1000) // same as event_id % 1000

    // Step 3: Look up byte offset from BST mapping table
    offset = bst_map[block] * 125     // block_offset * BLOCK_SIZE

    // Step 4: Calculate byte and bit position
    byte_index = index / 8            // integer division
    bit_index  = 7 - (index % 8)      // INVERTED bit order (MSB first)

    // Step 5: Read the flag
    byte_value = event_flags[offset + byte_index]
    flag_set   = ((byte_value >> bit_index) & 1) == 1

    return flag_set
```

### 4.4 Flag Write Algorithm

```
function set_event_flag(event_flags: []u8, event_id: u32, value: bool):
    // Same block/index/offset/byte/bit calculation as above
    ...
    if value:
        event_flags[offset + byte_index] |= (1 << bit_index)   // set bit
    else:
        event_flags[offset + byte_index] &= ~(1 << bit_index)  // clear bit
```

### 4.5 Key Detail: Bit Order

The bit index is **inverted**: `bit_index = 7 - (index % 8)`.
This means flag index 0 maps to bit 7 (MSB), flag index 7 maps to bit 0 (LSB).

---

## 5. Boss Kill Event Flag IDs

Each boss typically has TWO flags:
1. A "boss defeated" flag (the enemy is dead)
2. A "reward obtained" flag (the player received the boss's drops/runes)

### Major Boss Defeat Flags

```
Flag ID     Boss Name
--------    ---------
18000850    Margit, the Fell Omen (Stormhill)
1042360800  Godrick the Grafted (Stormveil Castle)
1035500800  Rennala, Queen of the Full Moon (Raya Lucaria)
1052520800  Starscourge Radahn (Caelid)
11000850    Morgott, the Omen King (Leyndell)
11050850    Godfrey, First Elden Lord (Leyndell, Ashen Capital)
15000850    Fire Giant (Mountaintops of the Giants)
15100850    Maliketh, the Black Blade (Crumbling Farum Azula)
15110850    Dragonlord Placidusax (Crumbling Farum Azula)
19000850    Radagon of the Erdtree / Elden Beast (Elden Throne)
12010850    Rykard, Lord of Blasphemy (Volcano Manor)
12050850    Mohg, Lord of Blood (Mohgwyn Palace)
12030850    Malenia, Blade of Miquella (Haligtree)
```

### Profile Summary Flags (in USER_DATA_10)

```
61100  Margit the Fell Omen
61101  Godrick the Grafted
61104  Morgott, the Grace Given
61107  Godfrey, First Elden Lord / Radagon
61118  Rennala, Queen of the Full Moon
61120  Malenia, Blade of Miquella
61130  Radahn the Starscourge
```

Note: The large flag IDs (18000850, 1042360800, etc.) are the in-save event flags.
The 6xxxx flags appear in profile summary / EMEVD event scripting context.
For reading boss kills from a save file, use the large flag IDs with the BST algorithm.

Full event flag reference: https://soulsmods.github.io/elden-ring-eventparam/

---

## 6. Character Name Location

### 6.1 Within Character Slot (PlayerGameData)

The character name is stored within the **PlayerGameData** struct at offset 0x98:

```
PlayerGameData offsets:
  0x00-0x07   unk0x0, unk0x4
  0x08        hp (u32)
  0x0C        max_hp (u32)
  0x10        base_max_hp (u32)
  0x14        fp (u32)
  0x18        max_fp (u32)
  0x1C        base_max_fp (u32)
  0x20        unk0x20 (u32)
  0x24        sp (u32)
  0x28        max_sp (u32)
  0x2C        base_max_sp (u32)
  0x30        unk0x30 (u32)
  0x34-0x3B   vigor, mind, endurance, strength, dexterity, intelligence, faith, arcane (u32 each)
  0x54-0x5F   unk padding
  0x60        level (u32)
  0x64        runes (u32)
  0x68        runes_memory (u32)
  0x6C        unk0x6c (u32)
  0x70-0x8B   poison/rot/bleed/death/frost/sleep/madness buildup (u32 each) + unk
  0x98        character_name: UTF-16LE, 16 characters max = 32 bytes
  0xB8        terminator: 2 bytes (null)
  0xBA        gender (u8)
  0xBB        archetype (u8)
  ...
```

**Encoding: UTF-16 Little Endian**, null-terminated, max 16 characters (32 bytes).

### 6.2 Within USER_DATA_10 (Profile Summary)

USER_DATA_10 also contains a ProfileSummary with an abbreviated copy of each
character's info. Each Profile entry (0x24C bytes) starts with:

```
Offset  Size   Field
------  -----  -----
0x00    32     character_name (UTF-16LE, 16 chars)
0x20    2      terminator
0x22    4      level (u32)
0x26    4      seconds_played (u32)
0x2A    4      runes_memory (u32)
0x2E    4      map_id (4 bytes)
0x32    4      unk0x34
0x36    0x124  face_data
0x15A   0xE8   equipment
0x242   1      body_type
0x243   1      archetype
0x244   1      starting_gift
0x245   7      padding
```

Total profile entry: 0x24C bytes. There are 10 profiles.
The ProfileSummary starts with 10 active_profiles bytes (booleans),
then 10 Profile entries.

---

## 7. USER_DATA_10 Layout (PC)

```
Offset   Size     Field
------   ------   -----
0x00     16       MD5 checksum (PC only)
0x10     4        version (u32)
0x14     8        steam_id (u64)
0x1C     0x140    Settings block
0x15C    0x1808   MenuSystemSaveLoad (character presets)
0x1964   varies   ProfileSummary:
                    - 10 bytes: active_profiles[10] (bool)
                    - 10 x 0x24C: Profile entries
                  gamedataman fields (5 bytes)
                  PCOptionData (0xB2 bytes, PC only)
                  KeyConfigSaveLoad (variable)
                  game_man_0x118 (8 bytes)
```

Total size: 0x60000 bytes (PS) / 0x60010 bytes (PC, including checksum).

---

## 8. USER_DATA_11 Layout

Contains the game's regulation/param data:

```
Offset   Size   Field
------   ----   -----
0x00     16     MD5 checksum (PC only)
0x10     4      magic bytes
0x14     4      unk0x4
0x18     4      regulation version (u32)
0x1C     4      size (u32)
0x20+    var    regulation data (params)
```

Total: 0x240010 bytes (PC) / 0x240020 bytes (PS).

---

## 9. Overall File Layout (PC)

```
Offset          Size        Content
-----------     ----------  -------
0x00000000      0x04        Magic: "BND4"
0x00000004      0x2F8       Rest of BND4 header + entry headers + names
                            (total preamble = 0x2FC bytes)
0x000002FC      0x280010    USER_DATA_000 (slot 0)
0x00280310      0x280010    USER_DATA_001 (slot 1)
0x00500320      0x280010    USER_DATA_002 (slot 2)
  ...                       (each subsequent slot at +0x280010)
0x01880930      0x280010    USER_DATA_009 (slot 9)
0x01B00940      0x60010     USER_DATA_010
0x01B60950      0x240020    USER_DATA_011
```

**Total file size: approximately 0x01DA0970 (~31 MB)**

Note: Exact offsets depend on BND4 entry header layout. The entry headers
at the start of the file tell you exactly where each USERDATA begins.
Always parse the BND4 headers rather than hardcoding slot offsets.

---

## 10. Encryption Notes (for reference / Nightreign)

Elden Ring **PC** saves are NOT encrypted. The BND4 entries contain raw data.

For other FromSoftware games / Nightreign that DO encrypt:
- Algorithm: AES-128-CBC
- Each USERDATA entry encrypted separately
- IV: First 16 bytes of the encrypted entry
- Encrypted payload: Remaining bytes after IV
- DS Remastered key: `01 23 45 67 89 AB CD EF FE DC BA 98 76 54 32 10`
- DS3 key: `FD 46 4D 69 5E 69 A3 9A 10 E3 19 A7 AC E8 B7 FA`
- Nightreign key: `18 F6 32 66 05 BD 17 8A 55 24 52 3A C0 A0 C6 09`

Checksum (post-decrypt, within entry):
```
checksum_data = entry_data[4 .. len-28]
md5_hash = MD5(checksum_data)
// Hash is stored at entry_data[len-28 .. len-12]
```

---

## 11. Parsing Strategy for Boss Checklist Tool

### Step-by-step for reading boss kill flags:

1. **Open** `ER0000.sl2`
2. **Verify** magic bytes = "BND4" at offset 0
3. **Parse BND4 header** (64 bytes) to get file_count and data_offset
4. **Parse entry headers** (32 bytes each, file_count entries)
5. **For each character slot** (entries 0-9):
   a. Read entry data using data_offset and entry_size from header
   b. Skip first 16 bytes (MD5 checksum on PC)
   c. Parse PlayerGameData to get character name at offset ~0x98 (UTF-16LE)
   d. Navigate to the event_flags byte array within the slot
   e. For each boss flag ID, use the BST algorithm to check if set
6. **For profile summary** (entry 10, USER_DATA_10):
   a. Skip checksum (16 bytes), read version (4), steam_id (8)
   b. Skip to ProfileSummary
   c. Read active_profiles[10] to know which slots are in use

### Minimum viable implementation:
- Parse BND4 to find slot data offsets
- Read character names from ProfileSummary in USER_DATA_10
- Read event flags from each active slot
- Check boss flags using BST lookup + bit manipulation

---

## 12. Key Resources

- ER-Save-Lib (Rust): https://github.com/ClayAmore/ER-Save-Lib
- er-save-manager (Python): https://github.com/Hapfel1/er-save-manager
- 010 Editor Template: https://github.com/ClayAmore/EldenRingSaveTemplate
- Event Flag Reference: https://soulsmods.github.io/elden-ring-eventparam/
- DS3SaveUnpacker (BND4 format): https://github.com/tremwil/DS3SaveUnpacker
- Souls Modding SL2 docs: https://sites.google.com/view/soulsmods/file-formats/sl2-files
- Event Flag System deep dive: https://deepwiki.com/The-Grand-Archives/Elden-Ring-CT-TGA/3.2-event-flag-system
