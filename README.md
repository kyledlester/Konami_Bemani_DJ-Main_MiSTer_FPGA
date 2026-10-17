# Konami Bemani DJ Main for MiSTer FPGA

<img width="320" height="240" alt="image" src="https://github.com/user-attachments/assets/8093bf4b-3908-40a9-8f49-b074d433a569" /> <img width="320" height="240" alt="image" src="https://github.com/user-attachments/assets/a4c8531e-faf0-4e32-ba1a-d14f912ebc67" />




Konami's **DJ Main** (GQ753, 1997–2002) is the board behind the original *beatmania* series and the
first *Pop'n Music* games: a 68EC020 at 16 MHz, K056832 tilemaps, a custom sprite chip, a K055555
mixer, two K054539 sound chips sharing 16 MB of sample RAM, and an IDE hard disk holding each
game's music. This core runs **every DJ Main game that has been dumped** (18 sets, all titles except for the original Pop'n Music Stage) from one core, using
the games' own MAME romsets and their **hard disks converted from the MAME CHDs**.

I created this core because I wanted to play these games on my MiSTer FPGA. I am posting it here and open
sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the
assistance of AI tooling.

MAME 0.289 `konami/djmain.cpp` is the hardware specification. The K056832 renderer, K054539,
TG68K integration and SDRAM stack come from ppriest's
[Arcade-KonamiGX_MiSTer](https://github.com/ppriest/Arcade-KonamiGX_MiSTer); see
[docs/THIRD-PARTY-KonamiGX.md](docs/THIRD-PARTY-KonamiGX.md).

> **Beta.** Multiple games have been tested as working, but it is difficult to test all of them due to the HDD file sizes. Every
> game boots, draws and plays in simulation. Reports welcome: see [Reporting problems](#reporting-problems).

## What you need

| File | Source | Put it in |
|---|---|---|
| `DJMain_YYYYMMDD.rbf` (24 kHz monitor or HDMI) **or** `DJMainSD_YYYYMMDD.rbf` (15 kHz CRT), see [Which build](#which-build-24-khz-or-crt-480i) | this repo (`Releases/`) | `/media/fat/_Arcade/cores/` |
| the game's MRA: from `MRA/` for DJMain, from `MRA/_CRT 480i/` for DJMainSD | this repo | `/media/fat/_Arcade/` (the `_CRT 480i` folder as a folder) |
| `<set>.zip` (for clones, the parent's zip too: `bmcmxaac` also needs `bmcompmx.zip`) | your MAME 0.289 set | `/media/fat/games/mame/` |
| `<disk>.hdd`, converted from the set's CHD (below) | your MAME set | `/media/fat/games/<set>/` |

Also needed: a 32 MB (or larger) SDRAM module, and an **exFAT** SD card for the images over 4 GB.

## Which build: 24 kHz or CRT 480i

The board's picture is 512 × 384 at 24 kHz (medium resolution), which a standard 15 kHz CRT can't
show. So the core comes as two builds, each with its own MRA for every game:

| Build | MRAs | Analog (VGA / JAMMA) | HDMI | For |
|---|---|---|---|---|
| **DJMain** | `MRA/<game>.mra` | the board's native 24 kHz, 57.997 Hz | the native picture | a 24 kHz / multisync monitor, or HDMI only |
| **DJMainSD** | `MRA/_CRT 480i/<game> [480i].mra` | **15 kHz 480i only** (541 lines, 15.69 kHz, interlaced); tested working on a 15 kHz CRT | the native picture, the same as DJMain | a standard-definition CRT: TV, PVM, 15 kHz arcade monitor |

The choice is the MRA you launch: a `[480i]` MRA loads DJMainSD, the others load DJMain. A build
can't come up in the wrong mode, because the mode is fixed in the build, not set by a menu or
`MiSTer.ini` option:

* **DJMainSD has no path from the 24 kHz picture to the analog output.** Until it has locked onto
  the game's picture (about 5 frames after the core loads or resets) the analog output is black
  with no sync at all; then it is 480i. It also ties MiSTer's scaler off the analog port, so no
  `MiSTer.ini` setting (`vga_scaler`, `forced_scandoubler`) can put another mode there.
* **DJMain** outputs the board's 24 kHz on analog, exactly as before.

**On a 15 kHz CRT, install only DJMainSD and the `_CRT 480i` MRAs.** Some 15 kHz monitors are
damaged by a 24 kHz signal, and with only the `[480i]` MRAs on the card there is nothing that can
send one. (Your MiSTer menu must already be set up for 15 kHz in `MiSTer.ini`, as for any
15 kHz setup.) With `direct_video=1`, HDMI carries the same 480i stream as the analog port.

How the 480i picture is made, by [crt480i](https://github.com/niknakniknak/crt480i): each field is
a new frame of the game, field 0 the even lines and field 1 the odd lines, so motion stays at the
board's 57.997 Hz and, at Height 1:1 with Deflicker off, every one of the 384 lines reaches the
screen unchanged. The output is phase-locked to the game: no dropped or repeated frames, and
under one frame of delay. The colours are the finished pixels, the same as HDMI shows.

### Supported games

| Game | Set | Year | Controls | Disk (CHD → `.hdd`) | Image | Hardware |
|---|---|---|---|---|---|---|
| beatmania (ver JA-B) | `bm1stmix` | 1997 | beatmania | `753jaa11` | 1.4 GB | tested working |
| beatmania 2nd MIX (ver JA-B) | `bm2ndmix` | 1998 | beatmania | `853jaa11` | 1.4 GB | |
| beatmania 3rd MIX (ver JA-B) | `bm3rdmix` | 1998 | beatmania | `825jab11` | 2.2 GB | |
| beatmania complete MIX (ver JA-C) | `bmcompmx` | 1999 | beatmania | `858jaa11` | 2.2 GB | |
| beatmania complete MIX (ver AA-C) | `bmcmxaac` | 1999 | beatmania | `858aac11` | 2.2 GB | |
| beatmania 4th MIX (ver JA-A) | `bm4thmix` | 1999 | beatmania | `847jaa11` | 2.2 GB | |
| beatmania 5th MIX (ver JA-A) | `bm5thmix` | 1999 | beatmania | `981jaa11` | 2.2 GB | |
| beatmania complete MIX 2 (ver JA-A) | `bmcompm2` | 2000 | beatmania | `988jaa11` | 4.3 GB | |
| beatmania Club MIX (ver JA-A) | `bmclubmx` | 2000 | beatmania | `993hdda01` | 4.3 GB | |
| beatmania featuring Dreams Come True (ver JA-A) | `bmdct` | 2000 | beatmania | `995jaa11` | 4.3 GB | |
| beatmania CORE REMIX (ver JA-A) | `bmcorerm` | 2000 | beatmania | `a05jaa11` | 4.3 GB | |
| beatmania 6th MIX (ver JA-A) | `bm6thmix` | 2001 | beatmania | `a21jaa11` | 6.0 GB | tested working |
| beatmania 7th MIX (ver JA-B) | `bm7thmix` | 2002 | beatmania | `b07jaa11` | 6.0 GB | |
| beatmania THE FINAL (ver JA-A) | `bmfinal` | 2002 | beatmania | `c01jaa11` | 10.1 GB | tested working |
| Pop'n Music (ver TA-A, HDD 1.01) | `popn1` | 1998 | Pop'n Music | `803_ta_hdd` | 3.2 GB | |
| Pop'n Music 2 (ver JA-A) | `popn2` | 1999 | Pop'n Music | `831jhdda01` | 4.3 GB | |
| Pop'n Music 3 (ver JA-A) | `popn3` | 1999 | Pop'n Music | `980hdda01` | 4.3 GB | tested working |
| Pop'n Stage EX (ver JB-A) | `popnstex` | 1999 | Pop'n Stage | `970jba11` | 3.2 GB | tested working |

From 4th MIX on, the disks are password-locked as on the original drives. The core unlocks each
with its game's own passwords (carried in its MRA), so a disk only works with its own game.

## Converting the disks

MiSTer mounts raw disk images, not CHDs. Convert each once with MAME's `chdman`: all of them with
the script here (PowerShell; a folder per set, images already converted are skipped):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\convert_chds.ps1 -MameDir C:\path\to\mame -OutDir C:\bemaniHDD
```

add `-Sets bm6thmix,bmfinal` for only some games, or one at a time:

```bash
chdman extracthd -i a21jaa11.chd -o a21jaa11.hdd
```

All 18 images come to about 65 GB. Copy each set's folder into `/media/fat/games/`, e.g.
`/media/fat/games/bm6thmix/a21jaa11.hdd`.

## Launch

1. Start the game from the Arcade menu (the MRA loads the ROMs and the game's settings).
2. Open the OSD → **Mount HDD** → select the game's `.hdd`. The board waits in reset until a disk
   is mounted.
3. The board runs its self test and loads the game's samples from the disk, as the real one does.

### What a correct boot looks like

beatmania 1st MIX (later games are similar):

| ~time | Screen |
|---|---|
| 0–25 s | memory check: PRG ROM, V ROM, O ROM, V RAM, OBJ RAM, COL RAM all OK |
| 25–70 s | S RAM (the 16 MB of sound RAM) checked |
| 70–80 s | HDD: samples loaded from the disk |
| ~80 s | title screen, then attract mode |

## Controls

Each MRA names the buttons for its game, so MiSTer's button mapping shows the right ones.

**beatmania** — two players, each with 5 keys and a turntable:

| MiSTer button | Default pad | Function |
|---|---|---|
| Key 1 – Key 5 | Y, X, B, A, R | the keys |
| Scratch Up / Scratch Down | L / – (also d-pad up / down) | turn the turntable |
| Start | Start | Start |
| Coin | Select | Coin |
| Effect, Test, Service | – | Effect; the cabinet's test and service switches |

The turntable can also be a **spinner**, the **mouse** (USB turntable controllers that present as
a mouse), or an **analog stick**: see *Controls* in the OSD.

**Pop'n Music** — one player, 9 buttons named by color left to right (white, yellow, green, blue,
red, blue, green, yellow, white), plus Coin, Test, Service. Default pad: Y, X, B, A, L, R for
buttons 1–6, Select for Coin. The game starts with the buttons.

**Pop'n Stage EX** — one player, 10 foot panels plus the Left / OK / Right selection buttons,
Coin, Test, Service. Default pad: Y, X, B, A, L, R for panels 1–6, Start for OK, Select for Coin.

## OSD

* **Mount HDD** — the game's raw disk image.
* **Aspect ratio**, **Audio mix** (stereo to mono).
* **Controls** — turntable stick (left / right / off), speed, direction, which player the mouse
  drives; **CPU speed**: 16 MHz (board, default) or 24 MHz.
* **DIP switches** — each game's, from MAME (coinage, difficulty, stages, demo sounds, event mode…).
* **CRT Adjust** (DJMain only) — the same tool as other MiSTer arcade cores: On/Off (Off by
  default), CRT H-Size (−12 % to +10 %), H-Position (±6-dot steps) and V-Shift, for lining up the
  24 kHz picture on an analog monitor. It moves the picture inside the line, never the sync, so the
  monitor can't lose lock, and every setting keeps all 512 × 384 pixels on screen. It changes the
  analog output only: HDMI keeps the untouched picture. Off is an exact passthrough; On adds one
  line (41 µs) of delay.
* **CRT 480i** (DJMainSD only) — Deflicker (Off, Mild, Medium, Medium+, Full: blends neighbouring
  lines to calm interlace flicker on fine detail), Height (1:1, or stretched to 200–240 lines a
  field), H-Position, V-Position.
* **Reset**.

## Timing and latency

These games judge to the frame, so the core keeps the board's timing exact:

* **Clocks as the board's.** 16 MHz dots, 660 × 418 → 57.997 Hz; the K054539s at exactly 48 kHz.
  The music and the scrolling notes keep the board's ratio, sample for sample.
* **Inputs are live.** Buttons are read straight from the controller when the game reads its
  ports, not once a frame. The turntable moves every scanline from buttons or a stick, and the
  moment a spinner or mouse reports.
* **No dropped frames.** The CPU runs about 1.85× MAME's 68020 model on the same code, so the
  game's work always finishes within its frame, including the busiest charts of 6th MIX and later,
  where MAME's CPU is fully loaded.
* **Sprites are taken at vblank start**, so every frame's notes are one consistent list (the game
  rebuilds it right after vblank).

For the lowest display latency, keep the native 58 Hz: on HDMI set `vsync_adjust=2` in
`MiSTer.ini` (it can go in a `[DJMain]` section) so the output locks to the core's 57.997 Hz
instead of being converted to 60 Hz. On analog video the 24 kHz output goes out directly; the
480i output (DJMainSD) is locked to the game's frames and adds under one frame.

## Known issues

* **Most games are not yet tested on hardware** (see the table). The simulation results are below.
* **The 24 kHz analog output (DJMain) is untested on hardware**; it is checked in simulation on
  this core's exact timing. (The 480i output, DJMainSD, is tested working on a 15 kHz CRT.)
* **CRT Adjust is untested on hardware** (no 24 kHz monitor yet); it passes 1,172 simulation
  checks on this board's raster. Reports from 24 kHz monitor owners are especially welcome.
* **Gamma is unavailable.** MiSTer's gamma correction needs at least 4 video clocks a pixel and
  this board's pixels are 3, so it would garble the colours; the core switches it off.
* **Cabinet lamps are not output**.
* **Not yet supported:** Other clone sets (2nd MIX JA-A, 3rd MIX JA-A and EA-A, complete
  MIX JA-B, hiphopmania complete MIX 1 / 2, beatstage complete MIX / 4th MIX, Pop'n Music AA-A /
  KA-A / JA-A). The core should run them, but they have no MRAs yet.

## Reporting problems

Open an issue on GitHub with the game (MRA name), what you saw and when (boot, attract, menus,
play), your video output (HDMI / analog, `vsync_adjust`) and controller, and if you can, a photo or
video. For a game that stops during boot, the last screen it shows is the most useful thing.

## Building

Quartus Prime Lite 17.0, one project with two revisions:

```bash
quartus_sh --flow compile DJMain -c DJMain
quartus_sh --flow compile DJMain -c DJMainSD
```

They give `output_files/DJMain.rbf` and `output_files/DJMainSD.rbf`, renamed
`DJMain_YYYYMMDD.rbf` and `DJMainSD_YYYYMMDD.rbf`. `DJMainSD.qsf` is `DJMain.qsf` plus the
`CRT_480I` macro.

## Verification

Before release, the core was checked in simulation (ModelSim) against MAME 0.289:

| Test | Result |
|---|---|
| Video: MAME's writes to the video chips replayed into the core, frames compared with MAME's (POST and play demo) | 0 differing pixels, also at twice the expected SDRAM latency |
| Video, every game: 10 attract-mode frames each | static content identical; differences only in moving sprites MAME draws mid-update |
| Boot: TG68K + the board running the real program | the first 2,059 video writes match MAME in order and by frame |
| Whole board on the real SDRAM path, through frame 80 | 82,000 VRAM and 15,000 palette writes identical; the POST screen 0 differing pixels |
| Disk: every game's ATA command trace from MAME | only SET FEATURES, SET MULTIPLE, READ MULTIPLE, and on the locked disks READ (expected to fail) and SECURITY UNLOCK, all implemented; no writes |
| Disk security (5th MIX's passwords) | reads refused while locked; wrong password refused; master then user unlock; reads clean after |

No ROM, disk or other game content is included in this repository or the RBF.

## Acknowledgements

* **ppriest's [Arcade-KonamiGX_MiSTer](https://github.com/ppriest/Arcade-KonamiGX_MiSTer)** — the
  K056832 tilemap renderer, the K054539, the TG68K integration and the SDRAM stack.
* TG68K.C (Tobias Gubener), Sorgelig's SDRAM controller and the MiSTer framework.
* **rmonic79's (Umberto Parisi) [MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust)** —
  CRT Adjust (`rtl/vendor/crt_adjust.sv`; the one change is its line buffer's width, made a
  parameter to hold this board's 660-dot line).
* **Chris Watson's [crt480i](https://github.com/niknakniknak/crt480i)** — the 480i module
  (`rtl/video/crt_480i.sv`, unchanged) and the framework change for it; its approach was inspired
  by rmonic79's `crt_vsize.sv` ([MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust)).
* MAME's `djmain.cpp` (smf) and Guru's hardware notes.

## License

GPL-3.0-or-later, as the code it builds on (`LICENSE`). `rtl/video/crt_480i.sv` is
GPL-2.0-or-later (its header), used here under GPL-3.0.
