# Konami Bemani DJ Main for MiSTer FPGA

Konami's **DJ Main** (GQ753, 1997–2002) is the board behind the original *beatmania* series and the
first *Pop'n Music* games: a 68EC020 at 16 MHz, K056832 tilemaps, a custom sprite chip, a K055555
mixer, two K054539 sound chips sharing 16 MB of sample RAM, and an IDE hard disk holding each
game's music. This core runs **every DJ Main game that has been dumped** (18 sets, all titles except for the original Pop'n Music Stage) from one RBF, using
the games' own MAME romsets and their **hard disks converted from the MAME CHDs**.

I created this core because I wanted to play these games on my MiSTer FPGA. I am posting it here and open
sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the
assistance of AI tooling.

MAME 0.289 `konami/djmain.cpp` is the hardware specification. The K056832 renderer, K054539,
TG68K integration and SDRAM stack come from ppriest's
[Arcade-KonamiGX_MiSTer](https://github.com/ppriest/Arcade-KonamiGX_MiSTer); see
[docs/THIRD-PARTY-KonamiGX.md](docs/THIRD-PARTY-KonamiGX.md).

> **Beta.** beatmania (1st MIX), 6th MIX and THE FINAL have been played on a MiSTer. Every other
> game boots, draws and plays in simulation against MAME and is waiting for its first hardware
> run. Reports welcome: see [Reporting problems](#reporting-problems).

## What you need

| File | Source | Put it in |
|---|---|---|
| `DJMain_YYYYMMDD.rbf` | this repo (`Releases/`) | `/media/fat/_Arcade/cores/` |
| the game's MRA | this repo (`MRA/`) | `/media/fat/_Arcade/` |
| `<set>.zip` (for clones, the parent's zip too: `bmcmxaac` also needs `bmcompmx.zip`) | your MAME 0.289 set | `/media/fat/games/mame/` |
| `<disk>.hdd`, converted from the set's CHD (below) | your MAME set | `/media/fat/games/<set>/` |

Also needed: a 32 MB (or larger) SDRAM module, and an **exFAT** SD card for the images over 4 GB.

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
powershell -ExecutionPolicy Bypass -File scripts\convert_chds.ps1 -MameDir C:\path\to\mame -OutDir D:\DJMain
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
instead of being converted to 60 Hz. On analog video the 24 kHz output goes out directly.

## Known issues

* **Most games are not yet tested on hardware** (see the table). The simulation results are below.
* **24 kHz analog video only**, as the board. A 15 kHz-only CRT can't show it; use a 24 kHz /
  multisync monitor, or HDMI. 24 kHz is current untested.
* **Cabinet lamps are not output**.
* **Not yet supported:** Other clone sets (2nd MIX JA-A, 3rd MIX JA-A and EA-A, complete
  MIX JA-B, hiphopmania complete MIX 1 / 2, beatstage complete MIX / 4th MIX, Pop'n Music AA-A /
  KA-A / JA-A). The core should run them, but they have no MRAs yet.

## Reporting problems

Open an issue on GitHub with the game (MRA name), what you saw and when (boot, attract, menus,
play), your video output (HDMI / analog, `vsync_adjust`) and controller, and if you can, a photo or
video. For a game that stops during boot, the last screen it shows is the most useful thing.

## Building

Quartus Prime Lite 17.0: `quartus_sh --flow compile DJMain -c DJMain` (output
`output_files/DJMain.rbf`, renamed `DJMain_YYYYMMDD.rbf`).

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
* MAME's `djmain.cpp` (smf) and Guru's hardware notes.

## License

GPL-3.0-or-later, as the code it builds on (`LICENSE`).
