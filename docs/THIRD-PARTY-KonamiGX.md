# Third-party code and licences

**This project is GPL-3.0-or-later.** `LICENSE` carries the GPLv3 text.

That is forced rather than preferred, and this file records why, what each dependency obliges, and
what it costs. The decision is also stated in [`docs/ROADMAP.md`](docs/ROADMAP.md) under "Design
decisions", because it constrains what can be vendored here for the life of the project.

## Why GPL-3, and why it is one-way

The CPU core and the custom-chip modules this project vendors are GPL-3 or LGPL-3. A work containing
them must be GPLv3 or GPL-3.0-or-later. That combination is lawful only because of the `sys/`
framework's own licence grant — see below — and the consequence is permanent in one direction:

> **Code can flow in from GPL-2-or-later MiSTer cores. It cannot flow back out to them.**

Anything written here is unavailable to a GPL-2-or-later core unless its author also offers it under
GPL-2-or-later separately. To relicense this repository back to GPL-2-or-later, every GPL-3
dependency below would have to be removed and replaced, or its authors would have to agree to
dual-license.

The sibling cores this project inherits its practice from — `Arcade-Psikyo_MiSTer`,
`Arcade-Fuuki_MiSTer`, `Arcade-Seta_MiSTer`, `Arcade-JalecoMS32_MiSTer` — already carry the GPLv3
text, so this is not a divergence from them.

## Status

Entries are marked **in the tree** once their `PROVENANCE.md` exists, and **planned** until then.
Each vendored directory's `PROVENANCE.md` names the exact upstream commit and records every local
change; this file records only what each dependency obliges.

## Dependencies

### TobiFlex/TG68K.C — LGPL-3.0-or-later — **in the tree**

<https://github.com/TobiFlex/TG68K.C> — the 68EC020 main CPU, in `rtl/cpu/tg68k/`, at
`ade33e39`. Modified: explicit zero initializers in two files, each with a §5(a) notice — see its
`PROVENANCE.md`.
Copyright (c) Tobias Gubener. Each file's header states LGPL-3.0-or-later; there is no separate
`LICENSE` file upstream. `Arcade-Psikyo_MiSTer` pins commit `ade33e396a1e647c2de9daf71ff9d5b3979639b2`
(2025-03-24) and its `rtl/cpu/tg68k/PROVENANCE.md` is the integration writeup to carry over.

LGPL-3 into a GPL-3.0-or-later work is direct. Obligations: publish the source, and keep each
modified file's change notice.

Note the upstream README's own caveat, because it is a technical risk rather than a licence one:
"The core does not value cycle accuracy." That is recorded under Phase 0 in the roadmap.

### jotego/jtcores — GPL-3.0-or-later — **in the tree** (four chips; two planned)

<https://github.com/jotego/jtcores>, Jose Tejada Gomez and contributors. Repository `LICENSE` is the
GPLv3 text and the individual files carry
`SPDX-License-Identifier: GPL-3.0-or-later` headers, which is the grant this project relies on.

All from commit `e7958c86`. **Verbatim except five files**, modified for GX and listed with their
reasons under "Local changes" in `rtl/video/k055673/PROVENANCE.md` (`jt053246.sv`,
`jt053246_scan.sv`, `jt053246_dma.v`) and `rtl/jtframe/PROVENANCE.md` (`jtframe_draw.v`,
`jtframe_objdraw_gate.v`). Each carries the §5(a) notice below and keeps its unmodified original
beside it as `*_upstream_reference`. `rtl/video/gx_obj.v` is derived from `jtsimson_obj.v` and says
so in its header.

| module | where | state |
|---|---|---|
| K053252 CRTC | `rtl/video/k053252/` | in the tree; upstream's differential bench passes here |
| K054156/K056832 tilemaps | `rtl/video/k056832/` | in the tree |
| K053246/K055673 sprites | `rtl/video/k055673/` | in the tree |
| K054338 alpha blender | `rtl/video/k054338/` | in the tree |
| jtframe HDL dependencies | `rtl/jtframe/` | in the tree — 12 files, taken one at a time |
| jtframe generator (Go) | `tools/jtframe/` | in the tree — the tool, not the framework |
| K053936 PSAC2 | `cores/rungun/hdl/jt053936.v` | *planned*, Type 1/3/4 only, out of the first scope |
| 93C46 EEPROM | `jotego/jteeprom`, `jt5911.sv` | *planned* |

Four of the vendored `*_mmr.v` files are **generated** by `tools/jtframe` rather than taken from
upstream's tree, because jotego generates them rather than committing them. The generator's own
template says "Do not add generated `*_mmr.v` files to git"; this project does anyway, and
`tools/jtframe/PROVENANCE.md` says why. `scripts/regen_mmr.sh --check` detects drift.

Obligations: publish the source, and **GPLv3 §5(a) — every modified file must carry prominent notice
that it was changed, and a date.** jotego's files already carry an SPDX header and an author line;
this project's changes append a dated notice to that block and never replace it.

One thing to carry in the `PROVENANCE.md` files, because it is a technical hazard rather than a
licence one: `modules/jt05415x/README.md` states that where MAME's comments and the silicon-derived
logic disagree, **the silicon is taken as the source of truth**. This project's accuracy target is
MAME. Both positions are correct for their own project; the roadmap's "Design decisions" says how
the collision is handled.

### furrtek/SiliconRE — GPL-2.0 — **not used as code**

<https://github.com/furrtek/SiliconRE> — the K054539 PCM chip, `Konami/054539/hdl/` (41 KB of
Verilog plus ROM contents dumped from the die), to land in `rtl/sound/k054539/`. Also the reference
schematics and register notes for the K053252, K054156, K054157, K054338 and K055555, which are
documentation rather than code.

**The licence version is not stated unambiguously upstream, and this project proceeds on an
assumption.** The facts, so the assumption can be re-checked rather than inherited:

- The repository's `LICENSE` file is the **GPLv2** text. GitHub's licence detector reports
  `gpl-2.0`.
- `Konami/054539/hdl/054539.v` carries **no SPDX header and no licence line** — only
  `// Konami 054539` and `// furrtek 2025`.
- The repository `README.md` makes no statement about "or later".
- GPL-2.0-**only** cannot be combined with the GPL-3 modules above. GPL-2.0-**or-later** can.

**Outcome: the HDL is treated as GPL-2.0-only and is not used.** The question was put to the author
(below) and closed without a grant; the project owner then decided to assume strictly GPL-2.0, not
later, which cannot be combined with this GPL-3 core. The K054539 is written from scratch against
MAME's `sound/k054539.cpp` (BSD-3-Clause) instead, with the register notes as documentation.

**The question has been put to the author:
[furrtek/SiliconRE#40, "Query: Use under GPL-3?"](https://github.com/furrtek/SiliconRE/issues/40).**
Check that issue before a release; a reply there is what converts this entry from an assumption into
a grant, and it is the commit to vendor from. The `Arcade-JalecoMS32_MiSTer` project hit the
identical question with the Seibu SPI YMF271, asked, and had an answer the same day.

If the answer turns out to be GPL-2.0-only, the fallback is a from-scratch K054539 against MAME's
`sound/k054539.cpp` and furrtek's register notes — the notes and schematics are documentation and
carry no such problem. That is a Phase 3 cost, and the roadmap records it as one.

### MiSTer-devel/Template_MiSTer and `sys/` — GPL-2.0-or-later

<https://github.com/MiSTer-devel/Template_MiSTer> — framework, `hps_io`, the scaler, `sys_top`.
**In the tree already**, as seeded.

The Template repository's own `LICENSE` carries the **GPLv2** text, but every source file header in
`sys/` reads "either version 2 of the License, or (at your option) any later version". **That
or-later clause is the only reason the combination in this repository is lawful**: it permits using
`sys/` under GPL-3.

Do not edit `sys/`. Framework updates overwrite it, and this project has no reason to diverge from
upstream. Build-time behaviour changes go in the `.qsf` as `VERILOG_MACRO` settings, which is a
project decision rather than a modification of `sys/`.

### rmonic79's CRT Adjust — GPL-3.0-or-later — **in the tree**

Umberto Parisi (rmonic79). `rtl/video/crt/crt_adjust.sv` (from `Arcade-Raiden_MiSTer`), copied
from `Arcade-Psikyo_MiSTer`, whose one fix (a signed `?:`) it keeps. The glue,
`rtl/video/gx_crt_chain.sv`, is this project's.

### wickerwaka's cheat engine — GPL-2.0-or-later — **in the tree**

Martin Donlon (wickerwaka), after Kitrinx's cheat handling: `rtl/cheat/cheatengine.sv`, from
[MiSTer-devel/Arcade-IremM92_MiSTer](https://github.com/MiSTer-devel/Arcade-IremM92_MiSTer) at
`68a4683`. Byte lanes changed for the big-endian 68020, the 4-byte compare fixed, two
declarations for Verilator; `rtl/cheat/PROVENANCE.md` lists them. GPL-2.0-or-later, so usable
here under GPL-3. The cheats themselves are converted from Pugsy's MAME cheats
(<https://www.mamecheat.co.uk/>) by `scripts/mame_cheats.py`.

### JimmyStones/Hiscores_MiSTer — GPL-3.0-or-later — **in the tree**

Alan Steremberg and Jim Gregory: `rtl/hiscore/hiscore.v`, version 14, by way of
Arcade-Psikyo_MiSTer's copy with its read-latency changes, and one local change;
`rtl/hiscore/PROVENANCE.md` has both. The tables are MAME's `hiscore.dat`
(`plugins/hiscore/`), written into the `.mra` by `scripts/build_mra.py`.

### ijor/fx68k — GPLv3 — *planned*

<https://github.com/ijor/fx68k>, Copyright (c) 2018, 2021 Jorge Cwik. The cycle-accurate 68000 for
the sound CPU, to land in `rtl/cpu/fx68k/`. `Arcade-Seta_MiSTer` carries a copy with its
`PROVENANCE.md` and `LICENSE`. GPLv3 into GPL-3.0-or-later is direct.

### Sorgelig's `sdram.v`, as adapted by the sibling cores — GPL-3.0-or-later — *planned*

Copyright (c) 2018 Sorgelig. `Arcade-Seta_MiSTer/rtl/memory/sdram/` holds the adapted version,
**including the `dq_in` capture fix** that LESSONS_LEARNED insists on. Carry that copy and its
`PROVENANCE.md`, not an older one.

## Reference material, not code

MAME (<https://github.com/mamedev/mame>) is this project's **behavioural specification**. No MAME
source is copied into this repository. `src/mame/konami/konamigx.cpp`, `konamigx_v.cpp`,
`konamigx_m.cpp` and the custom-chip devices are BSD-3-Clause, copyright R. Belmont, Acho A. Tang,
Phil Stroffolino and Olivier Galibert; the roadmap cites them by file and line as documentation.

furrtek's schematics, pinouts, traces and register notes are used the same way — as documentation of
what the chips do. Only `Konami/054539/hdl/` is code, and it is covered above.

## Release checklist

Before publishing a build:

1. Every vendored directory has a `PROVENANCE.md` naming the upstream repository, the exact commit,
   the licence **as stated in the files** (not as reported by a licence detector), and what was
   changed here.
2. Every modified vendored file carries a dated GPLv3 §5(a) change notice, appended to whatever
   upstream wrote rather than replacing it.
3. Every file this project wrote starts with `// SPDX-License-Identifier: GPL-3.0-or-later` and a
   copyright line.
4. `sys/` is unmodified against upstream Template_MiSTer.
5. `LICENSE` is the GPLv3 text.
6. **The K054539 licence question above is answered** —
   [furrtek/SiliconRE#40](https://github.com/furrtek/SiliconRE/issues/40) — or that code is not in
   the build.
