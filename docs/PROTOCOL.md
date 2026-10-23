# AULA F75 HID protocol

Everything the plugin sends or expects, with the evidence for each claim.
Evidence tags:

- **[driver]** read from the vendor package `AULA F75 Setup v2.0 20260514.exe`
  (`OemDrv.exe` strings/decompilation, `Dev/kb/fr/KB.ini`, `Text/en/text.xml`).
- **[capture]** confirmed by USB captures of the vendor driver talking to a real
  F75 (the `.pcapng` set published in Godera3/peripheral-toolkit, re-decoded
  here).
- **[community]** reported by other open-source implementations but not
  independently confirmed by us.
- **[inferred]** our reading; could be wrong.

The keyboard is a SinoWealth "BYCOMBO4" design. The vendor driver picks the
`CDevG5KB` device class for it because the profile says `Fw=24` (0x18)
**[driver]**.

## Identity

| | VID:PID | Vendor HID interface | Report | Evidence |
|---|---|---|---|---|
| USB | `258a:010c` | usage page `0xFF00`, usage 1 | feature report ID `0x06`, 520 bytes | [driver] KB.ini `VID/PID`; [capture] |
| 2.4 GHz dongle | `3554:fa09` | usage page `0xFF02` | output report ID `0x13`, 20 bytes | [driver] KB.ini `VID_Wireless/PID_Wireless`; [capture] |

KB.ini also carries `Psd=3,0,0,0,0,cd`, a 6-byte "password" the driver reads
back from the device (`GetPassword`, read command `0x82` sub `1`
**[community]**) to make sure the connected board is the model the profile
describes. The plugin does not check it.

## USB framing (CDevG5KB)

Every transfer is one 520-byte feature report:

```
byte 0    0x06           report ID
byte 1    cmd            bit 7 set = read
byte 2    sub            layer / group selector, usually 0
byte 3    0x00
byte 4    total          number of 512-byte chunks in this transfer
byte 5    index          0-based chunk number
byte 6-7  length         bytes of payload in this chunk, little-endian
byte 8..  payload        up to 512 bytes, zero padded
```

**[capture]** Header of the lighting write: `06 04 00 00 01 00 80 00`; of the
colour table write: `06 0a 00 00 01 00 00 02`; of the per-key write:
`06 06 00 00 01 00 7a 01`.

Reads send the same header with `cmd | 0x80` and an empty payload, then issue
GET_FEATURE on the same report ID. The reply echoes the command in byte 1 and
carries the data from byte 8. The driver waits about 20 ms before each packet
and retries SET_FEATURE up to three times **[driver]** (`AccessData: retry
SetFeature now`, `AccessData: GetFeature Failed, cmd id unmatch`).

On Linux this is `HIDIOCSFEATURE` / `HIDIOCGFEATURE` on the hidraw node of
the vendor interface; the kernel turns them into SET_REPORT / GET_REPORT
control transfers.

### Commands

| Write | Read | Payload | Evidence |
|---|---|---|---|
| `0x03` sub=layer | `0x83` | key matrix, 128 × 4 bytes; last entry `00 00 5A A5` | [driver] `MatrixLen=128`, `CRC=1`; [community] |
| `0x04` | `0x84` | lighting / settings block, 128 bytes | [capture] |
| `0x05` | `0x85` | macro buffer | [driver] strings `SetMacro` |
| `0x06` | `0x86` | per-key colours, 126 × RGB = 378 bytes, indexed by matrix index | [capture] (vendor "Self-define" write) |
| `0x0a` | `0x8a` | effect colour table, 512 bytes | [capture] |
| `0x0b` | – | screen parameters (models with a display) | [driver] `SetScreenParam` |
| `0x11` | – | reset, 1 byte | [community] |
| – | `0x82` sub=1 | 6-byte model password | [community] |
| – | `0x87` sub=2 | battery, byte 0 = percent | [community] |

The vendor driver's `CDevG5KB` virtual functions line up with these:
`SetMatrix/GetMatrix`, `SetLED/GetLED`, `SetMacro/GetMacro`, `SetGame/GetGame`
(= per-key colour group), `SetLedRgbTab/GetLedRgbTab`, `SetScreenParam`,
`ResetDevice`, `GetPassword`, `ReadPower` **[driver]** (strings in
`OemDrv.exe`).

## Lighting / settings block (`0x04`, 128 bytes)

A block captured from a real board, vendor driver, effect "Fixed on":

```
000: 00 03 03 01 00 00 04 04 07 00 01 20 01 00 00 00 00 00 02 00 02 01 00 ff 0a 00 00 01 01 00 03 01
020: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ff ff 09 40 09 47 09 47
040: 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47 09 47
060: 09 37 07 47 07 47 07 44 07 44 07 44 07 44 07 44 07 44 07 44 04 09 04 04 04 04 04 04 04 04 5a a5
```

| Offset | Meaning | Evidence |
|---|---|---|
| `0x03` | debounce, 1..4 (vendor UI `ShowDebounce=0x04000101`) | [community] decompile; [driver] range |
| `0x09` | `1` while the custom per-key effect is active, else `0` | [capture] only the self-define write sets it |
| `0x0a` | **active effect id** | [capture] the only byte that differs between the 17 effect captures |
| `0x18` | sleep timer in 30 s units (`SleepHW`), `0` = never | [capture] wireless sleep capture patches byte 24; [driver] `SleepHW=2,3,4,6,8,10,20,30,40` ↔ `SleepUI=60…1200` s |
| `0x38 + 2·id` | brightness for effect `id`, 0..9 | [capture] brightness capture patches `0x3a` with effect 1 active |
| `0x39 + 2·id` | `speed << 4 \| colour`; speed 0..4, colour 0..6 picks one of the effect's seven table colours, 7 = colourful/random | [capture] `0x3b` flips `0x40`↔`0x47` with the "Colorful" switch; [driver] `Speed=0..4`, `Light=0..9` |
| `0x7e` | signature `5A A5` | [capture] |

The plugin never writes this block without first reading it and checking the
signature, so unknown bytes (`0x00`–`0x08`, `0x0b`–`0x17`, …) are preserved.

### Effect ids

Names from `text.xml` (`tc_kb_led1…20`), ids from the captures. The vendor
profile's `LedMask=0x22100` hides ids 9, 14 and 18 from the F75's UI
**[driver]**, and indeed no capture exists for them; the firmware may or may
not implement them.

| id | name | speed | colour | | id | name | speed | colour |
|---|---|---|---|---|---|---|---|---|
| 0 | Off | | | | 10 | Retro snake | ✓ | ✓ |
| 1 | Fixed on | | ✓ | | 11 | Neon stream | ✓ | ✓ |
| 2 | Respire | ✓ | ✓ | | 12 | Reaction | ✓ | ✓ |
| 3 | Rainbow | ✓ | | | 13 | Sine wave | ✓ | ✓ |
| 4 | Flash away | ✓ | ✓ | | 14 | Retinue scanning (hidden) | ✓ | ✓ |
| 5 | Raindrops | ✓ | ✓ | | 15 | Rotating windmill | ✓ | |
| 6 | Rainbow wheel | ✓ | ✓ | | 16 | Colorful waterfall | ✓ | |
| 7 | Ripples shining | ✓ | ✓ | | 17 | Blossoming | ✓ | |
| 8 | Stars twinkle | ✓ | ✓ | | 18 | Rotating storm (hidden) | ✓ | ✓ |
| 9 | Shadow disappear (hidden) | ✓ | ✓ | | 21 | Custom / per-key ("Self-define") | | |

A note on `KB.ini`'s `LedOptN = a,b,speed,light,direct,random,color` lines:
the first number is the id written to the device (it runs 1…18, then 21 for
self-define), the second is an internal animation index used only by the
driver's on-screen preview. One community project swapped the two; the
captures settle it.

## Effect colour table (`0x0a`, 512 bytes)

Seven RGB triplets per effect, 21 bytes per slot, slot = effect id:

```
offset = 21 * effect_id + 3 * colour_index       (colour_index 0..6)
0x1fa   signature 5A A5
```

**[capture]** The dongle "colour change" capture changes exactly bytes 21–23
(effect 1, colour 0). A fresh board has `red, green, blue, yellow, magenta,
cyan, white` in every slot. The low nibble of the effect's speed/colour byte
in the lighting block selects which of the seven is shown; the plugin always
writes colour 0 and selects it.

## Per-key colours (`0x06`, 378 bytes)

`3 bytes × 126 LEDs`, LED index = the key's matrix index from `KB.ini`
(`aula-f75 keys` prints the map). After writing it the vendor driver sets
effect `21` and byte `0x09 = 1` in the lighting block **[capture]**. Over
USB only; the dongle command for it is unknown.

## Key matrix (`0x03`, 512 bytes per layer)

Not used by the widget; `aula-f75 backup --matrix` / `restore --matrix`
move it verbatim. Layout from `KB.ini` and the driver's
`keyinfo_to_hardware_code` **[community]**: 4 bytes per key,
`00 mods hid hid2` for keys, `02 00 usageHi usageLo` for consumer keys,
`01 btn 01 00` for mouse buttons, `03 mode count id` for macros, layer 0 is
the base layer and layer 1 the Fn layer. The entry at index 127 is
`00 00 5A A5` **[driver]** (`CRC=1`).

## 2.4 GHz dongle framing

20-byte output reports, report ID `0x13`:

```
byte 0    0x13
byte 1    cmd
byte 2    total pages
byte 3    page index
byte 4    bytes of payload in this page (14, or less on the last page)
byte 5-18 payload
byte 19   checksum = sum(bytes 0..18) & 0xff
```

**[capture]** All 48 frames of the dongle "set effect" sequence verify with
that checksum. The sequence the vendor driver sends is:

1. `cmd 0x09`, 37 pages: the 512-byte colour table (same bytes as USB `0x0a`).
2. `13 44 01 00 00 … 58`: a one-frame probe/read request for the lighting
   block (`0x44` = `0x04 | 0x40`), followed by a ~170 ms pause.
3. `cmd 0x04`, 10 pages: the 128-byte lighting block (same bytes as USB).

Changing only sleep uses steps 2–3. The plugin mirrors this: colour changes
send 1–3, everything else 2–3, with 25 ms between frames.

Reading over the dongle (`0x44` and the keyboard streaming pages back as input
reports) is implemented best-effort from a community description
**[community]**; if nothing usable comes back within 1.5 s the plugin falls
back to the captured template block above and says so on stderr. In that
case every write re-asserts the template's unknown bytes, which matched a
factory board but might differ on yours.

The dongle has no interrupt OUT endpoint, so hidraw `write()` goes out as a
SET_REPORT control transfer, which is exactly what the vendor driver does.

## What is *not* known

- Meaning of lighting-block bytes `0x00`–`0x02`, `0x04`–`0x08`, `0x0b`–`0x17`,
  `0x19`–`0x37` and `0x64`–`0x7d` (preserved verbatim).
- Whether the hidden effects 9, 14, 18 exist in the F75 firmware.
- Dongle commands for per-key colours, key matrix and macros.
- The macro buffer layout (documented by open-aula, not needed here).
- Battery read-out over USB (`0x87`) was not tested; the F75 reports it to the
  vendor driver only over the dongle.
