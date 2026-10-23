# How the F75 protocol was recovered

A log of the reverse-engineering pass behind this plugin, in the
"evidence first" spirit of the
[awesome-reverse-engineer-anything](https://github.com/AIshihzong/awesome-reverse-engineer-anything)
case studies: every claim in `PROTOCOL.md` is tagged with where it came from,
and the places where we are inferring are called out.

Input: `AULA F75 Setup v2.0 20260514.exe` (2.4 MB), the vendor's Windows
driver for the French-layout F75.

## 1. Unpack the installer

`file` says PE32 GUI; the string `Inno Setup` sits at offset 89692. So:

```
innoextract -e -d extracted "AULA F75 Setup v2.0 20260514.exe"
```

Payload worth reading:

| file | what |
|---|---|
| `app/OemDrv.exe` (2.7 MB, MFC 9, x86) | the actual driver/configurator |
| `app/Dev/kb/fr/KB.ini` | device profile: USB ids, `Fw=24`, `MatrixLen=128`, `Psd`, effect option table, sleep tables, key rectangles + matrix indexes |
| `app/Text/en/text.xml` | UI strings, including the 20 effect names in order |
| `app/Dev/kb/fr/Cartoon/*.txt`, `ET/*.txt` | key groupings for the on-screen animation preview (not sent to the device) |
| `app/Cfg.ini` | app settings (`Appdir=BYCOMBO4`, `Ver=0x200`) |
| `app/InitSetup.dll`, `uninstall.dll` | installer helpers, uninteresting |

Nothing in the package is a kernel driver: the whole thing is user-mode HID
(`HidD_SetFeature` / `HidD_GetFeature` imports in `OemDrv.exe`).

## 2. Read the profile before the binary

`KB.ini` is the cheapest source of truth:

```
Fw=24                 -> firmware family 0x18 -> CDevG5KB class in the exe
VID=0x258a PID=0x010C -> wired
VID_Wireless=0x3554 PID_Wireless=0xfa09
Psd=3,0,0,0,0,cd      -> 6-byte model password the exe compares
CRC=1                 -> matrix block ends in 5A A5
MatrixLen=128
Light=0..9 Speed=0..4
SleepUI=60,90,120,180,240,300,600,900,1200
SleepHW=2,3,4,6,8,10,20,30,40           -> 30 s units
LedMask=0x22100                          -> hides UI effects 9, 14, 18
LedOpt1..20 = id, previewIndex, speed, light, direct, random, color
[KEY] K1=27,33,53,61, 0x02,0x1B,0x00,0   -> rect, type, VK, flags, matrix index
```

The `[KEY]` section gives the LED/matrix index of every physical key, which
is what the per-key colour command is indexed by.

## 3. Strings in `OemDrv.exe`

A UTF-16/ASCII string sweep (`strings_*.txt` in the scratch dir) exposes the
driver's internal structure without disassembling anything:

- Device classes: `CDev3632`, `CDev916KB`, `CDevComboFilm`, `CDevG5KB`,
  `CDevG5MS`, `CHidDev`. `Fw` in the profile selects which one is used; 0x18
  → `CDevG5KB`.
- `CDevG5KB` operations: `SetMatrix layer=%d`, `GetMatrix`, `SetMacro`,
  `SetLED`/`GetLED`, `SetGame`/`GetGame`, `SetLedRgbTab`/`GetLedRgbTab`,
  `SetScreenParam`, `SendSelfData`, `ReadPower`, `GetPassword`, `Reset`,
  `GetOnline`.
- Transport: `AccessData: SetFeature nErr=%d, nCmdID=%x`,
  `AccessData: GetFeature Failed, cmd id unmatch, Buffer[2]=%x`,
  `AccessData: retry SetFeature now`, `AccessData CRC err for nCmdID=%x,
  retry now`. So: feature reports, the reply must echo the command id, and
  there is a retry loop.
- Semantics: `FillCfg_LowDaly: Cfg[2](Debounce)=%d, Cfg[8](Tap)=%d,
  Cfg[9](Sleep)=%d`, `SideLED: mode=%d, nLight=%d, nSpeed=%d, nColor=%d`,
  `Key[%d][%d] Set To Macro`, `keyinfo_to_hardware_code can't find macro id`.
- Cloud features (`queryprofile.php`, `submitmacro.php`,
  `http://120.79.152.79/update/`) that the Linux port deliberately ignores.

## 4. Published captures as ground truth

Rather than only trusting the decompiler, the byte layout was pinned to USB
captures of this exact driver talking to an F75, published by
Godera3/peripheral-toolkit (`keyboard/wired/*.pcapng`, already split into
`fragments/*.bin`). Re-decoding them here:

- Every wired effect change is three 520-byte feature reports:
  `06 0a …` (colour table), `06 84 …` (a read request for the lighting block,
  payload all zero) and `06 04 …` (lighting block).
- Diffing the lighting block across the 17 effect captures: **only byte 10
  changes** (plus byte 9 for self-define and one stale colour nibble at
  `0x3b` from an earlier UI action). That is the effect id, and it runs
  0x00, 0x01 … 0x11, 0x15, which matches the *first* number of each `LedOpt`
  line and the order of `tc_kb_led1..20`, and skips exactly the three ids
  that `LedMask` hides.
- The wireless captures carry the same 128-byte block, in 14-byte pages
  under report `0x13`, so the dongle captures of single-field changes locate
  fields inside the block: brightness → page 4 byte 7 → `0x3a`, colourful →
  `0x3b` (`0x47`/`0x40`), colour → colour table bytes 21–23, sleep → page 1
  byte 10 → `0x18`.
- The self-define capture replaces the colour-table report with
  `06 06 00 00 01 00 7a 01` + 378 bytes: command `0x06` is per-key RGB,
  126 LEDs, indexed like `KB.ini`. (One community port labels `0x06` "game
  mode" from the `SetGame` string; the capture shows what the F75 driver
  actually sends through it.)

The checksum of the 20-byte dongle frames is `sum(bytes[0..18]) & 0xff`,
verified on all 48 + 11 captured frames (see `tests/test_protocol.py`).

## 5. Decompilation (Ghidra, headless)

`OemDrv.exe` was imported into Ghidra 12 and the functions referencing the
strings above were decompiled with `tools/ghidra/DumpByStrings.java`
(headless `analyzeHeadless … -postScript DumpByStrings.java`). The excerpts
kept in `docs/evidence/` confirm the framing used by `CDevG5KB`: the
8-byte header `06 cmd sub 00 total idx len16`, 512-byte chunking, the
20 ms pre-packet sleep, the three-attempt `HidD_SetFeature` retry, and the
`Buffer[1] == cmd` check on `HidD_GetFeature` replies. See
`docs/evidence/README.md` for what was and was not confirmed there.

## 6. Cross-checks against other open implementations

| project | agrees | disagrees / adds |
|---|---|---|
| paulcoding810/open-aula (`g5kb.js`, decompiled the same exe) | framing, commands, `0x3a` table, sleep `0x18`, debounce `0x03`, colour table 21-byte slots | swaps the `LedOpt` columns, so its "hw" ids are wrong for the F75 |
| Godera3/peripheral-toolkit (captures) | effect ids, dongle framing, checksum | treats the dongle sequence as an opaque replay |
| RustamSheoran/aula-f75 (WebHID) | report 6 / 520 bytes, `0x84`/`0x04`, offset 10 | its per-effect table base (64) is off by two from the captures |
| leisiji/AulaSofwareLinux (`proto.rs`) | framing, read handshake, retries | calls `0x06` "game mode" |
| JavaProgswing/aula-f75 (dongle) | report `0x13`, checksum, `0x44` read | documents keymap reads over the dongle, which this plugin does not use |

## 7. Decisions taken in the port

- Read-modify-write only; never synthesise the lighting block from scratch
  over USB. Refuse to write when the `5A A5` signature is missing.
- Index the per-effect brightness/speed table and the colour table by effect
  id (captures confirm id 1; ids 2–18 follow the same stride in the vendor
  decompile).
- Dongle support mirrors the vendor's frame order and pauses, and falls back
  to a captured template when a read fails, loudly.
- Keep the key matrix out of the UI. Remapping is a different project and a
  bad matrix write leaves you with a keyboard that types the wrong keys.
