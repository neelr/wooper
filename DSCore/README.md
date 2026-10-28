# Wooper DS mode

Native SwiftUI frontend to the pinned `Vendor/melonds` libretro core. The core is
built for physical arm64 iOS devices with the interpreter and software renderer;
JIT and networking are disabled. No commercial games or Nintendo BIOS are bundled.
The upstream FreeBIOS and generated firmware provide the default DS boot path.
DSi is not supported by this frontend.

## Build

1. Install Xcode 27.1 or later and XcodeGen.
2. Run `./scripts/build-ds-core.sh` from the repository root.
3. Run `xcodegen generate`, then build the Wooper scheme for an iOS device.
4. Supply local Secrets.swift and PaperyConfig.swift as for the other app features.

The generated static archive is ignored by Git. The pinned upstream source,
libretro support files, adapter and build script are included or referenced by
submodule, with upstream licensing in MELONDS-LICENSE. melonDS is GPLv3; preserve
its notices and corresponding-source requirements when redistributing builds.
The current build script targets devices, not the Simulator.

## Games and saves

The DS tab appears only on Duo in regular-width layouts. It pauses when hidden,
when the phone folds to compact width, when backgrounded, or on audio interruption.
DS is presented by a full-screen UIKit hosting controller that requests portrait
and the iOS interface-orientation lock from the library onward. It uses iOS 27.1
ArrangementView to arrange its screens around reserved fold regions.

The bridge memory-maps the ROM read-only for the lifetime of the core session,
keeping the libretro reset pointer valid without a byte-by-byte copy of large ROMs.

Import raw `.nds` files through the DS library's + button. ZIP archives are not
supported. The ROM header and size are validated before loading. Duplicate imported
filenames are rejected rather than replacing a game. No ROMs are sent to a server.

To load a file supplied in chat without a rebuild:

    ./scripts/load-ds-rom.py '/absolute/path/Game.nds'

The script copies to Flippy by default; use `--device <UDID>` for another device.
It replaces only a ROM with the exact same filename; it never removes saves.
Files is also available under On My iPhone → wooper → DS after installation.

- `Documents/DS/ROMs`: ROM library.
- `Documents/DS/Saves`: cartridge `.sav`, automatic state, and quick-save slot.
- `Documents/DS/System`: optional user-supplied `bios7.bin`, `bios9.bin`, `firmware.bin`.

Save states are tied to the pinned core version. A normal in-game save is preferable
for long-term progress. Automatic state is written on pause and restored at launch;
quick save/load is in the game toolbar. Force-quitting during execution may lose
progress since the last save. The Mic control generates microphone noise; it does
not record the real microphone. Hardware controllers and DS multiplayer are not
implemented.

## Smoke test

`scripts/make-ds-test-rom.py` builds a tiny original homebrew ROM using clang's ARM
assembler. It displays a red upper screen and blue lower screen; holding A turns
the upper screen green. This checks rendering and buttons, not commercial-game
compatibility. Copy this generated file with the loader above.
