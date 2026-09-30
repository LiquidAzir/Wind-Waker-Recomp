#!/usr/bin/env python3
"""The Windows download: the app folder the builder made, without the game.

  python scripts/windows/package_release.py VERSION [--app build/windows/BlueWake] [--out build/windows/release]

VERSION as the Mac release names it (0.1.0).

Copies the app (BlueWake.exe, the game module, the runtime DLLs, Aurora's
pipeline seed, the DSP files) and nodtool.exe (which unpacks a Dolphin .rvz on
the player's first launch) into WindWakerRecomp/, adds a README and the
licenses, and writes WindWakerRecomp-VERSION-windows-x64.zip and its .sha256
(named like the Mac release's WindWakerRecomp-VERSION-macos-arm64.zip).
Nothing from the disc goes in: not the disc image, main.dol, the RELs or any
save. The first launch asks for the player's own disc and prepares it
(windows/src/win_disc.c). The script refuses to write the zip if a file from
the disc, a save or a debug database would be in it.
"""
import argparse
import hashlib
import json
import re
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NAME = "WindWakerRecomp"
# Never in a download: the disc and anything taken from it, saves, debug
# databases and the builder's optimization profiles.
PRIVATE = re.compile(r"\.(iso|gcm|rvz|wia|gcz|ciso|nfs|wbfs|dol|rel|arc|card|gci|sav|raw|pdb|profdata|profraw)$", re.I)
APP_FILES = re.compile(r"\.(exe|dll)$", re.I)
DEPS = ROOT / "build/windows/app/_deps"
# name in the download: where the text is (the first that exists)
LICENSES = {
    "BlueWake-GPL-3.0.txt": [ROOT / "LICENSE"],
    "RecompCore-COPYING.txt": [ROOT / "ref/recompcore/COPYING"],
    "Aurora-MIT.txt": [ROOT / "ref/recompcore/GXRuntime/graphics/aurora/LICENSE"],
    "nodtool-MIT.txt": [ROOT / "windows/licenses/nod-MIT.txt"],
    "Dawn.txt": [ROOT / "windows/licenses/Dawn-BSD-3-Clause.txt"],
    "DirectXShaderCompiler.txt": [ROOT / "windows/licenses/DirectXShaderCompiler-LICENSE.txt"],
    "SDL3-zlib.txt": [DEPS / "sdl3_prebuilt-src/licenses/SDL3/LICENSE.txt"],
    "zlib.txt": [DEPS / "zlib-src/LICENSE.md", DEPS / "zlib-src/LICENSE"],
    "libpng.txt": [DEPS / "png-src/LICENSE"],
    "Dear-ImGui-MIT.txt": [DEPS / "imgui-src/LICENSE.txt"],
    "fmt.txt": [DEPS / "fmt-src/LICENSE"],
    "FreeType.txt": [DEPS / "freetype-src/LICENSE.TXT"],
    "xxHash.txt": [DEPS / "xxhash-src/LICENSE"],
    "zstd.txt": [DEPS / "zstd-src/LICENSE"],
    "Abseil-Apache-2.0.txt": [DEPS / "abseil-cpp-src/LICENSE"],
    "Tracy.txt": [DEPS / "tracy-src/LICENSE"],
}

README = """Wind Waker Recomp {version} for Windows (BlueWake)

The Legend of Zelda: The Wind Waker (GameCube, USA), statically recompiled to
run natively on Windows x64 with Direct3D 12.

You need your own copy of the game: the GameCube USA disc (GZLE01, revision 0)
as a disc image, an .iso or .gcm file or a Dolphin .rvz. None is included.

Start
  1. Unpack this whole folder anywhere and run BlueWake.exe. BlueWake is not
     signed, so Windows may say it protected your PC: choose "More info",
     then "Run anyway".
  2. The first time, BlueWake asks for your disc image. It checks that it is
     the USA disc, prepares it once (a few seconds; an .rvz is first unpacked
     to an ISO, about 1.4 GB, in %APPDATA%\\BlueWake) and remembers it.
  3. Later launches start the game straight away. To use another disc image:
     F1 (settings), Sound and files, "Choose another disc image".

Needs Windows 10 or 11 (64-bit), a Direct3D 12 GPU, and a CPU with AVX2
(Intel Haswell, AMD Zen or newer).

Smooth Motion: 60 FPS by default, drawn from the game's 30 with in-between
frames. F10 turns it off and on; the settings choose 60 or 120 FPS (120 on a
display of 100 Hz or more). "60 Hz gameplay" in the settings (experimental)
runs the game itself at 60.

If it runs slowly: F9 shows the frame rate ("60 FPS (game 30)" is full speed).
Please send the newest session log (%APPDATA%\\BlueWake\\logs\\session-*.log)
after a minute of play with your report: it names your CPU and GPU and, each
second, which part of the PC held the game back.

Keyboard: W A S D control stick, T F G H C-stick, arrow keys D-pad,
J K U I = A B X Y, E R Q = L R Z, Return START, Space jump, Shift sprint.
Mouse: click the game, then move the mouse to turn the camera (Esc gives the
mouse back); the wheel zooms.
Controller (Xbox, PlayStation, Switch Pro, ...): the right stick turns the
camera directly and aims, its click is first person (and back out), the left
stick zooms the telescope and the Picto Box, the left bumper jumps and a click
of the left stick sprints. Settings, Controls: the game's own right stick
instead, the right stick's speeds and directions.
F1 or Esc settings, F11 or Alt+Enter fullscreen, F10 Smooth Motion, F9 frame rate.
F5 saves a save state and F8 loads the latest one (%APPDATA%\\BlueWake\\states);
they belong to this build. Use the game's own save for anything you keep.
Climbing any wall on a stamina wheel: settings, Mods, "Climb any wall".
BlueWake.exe --help lists the command-line options.

Saves, settings, the prepared disc and session logs: %APPDATA%\\BlueWake

Source and documentation: https://github.com/elliotttate/Wind-Waker-Recomp
(docs/WINDOWS.md), and the source archive beside this download. BlueWake's
code is under the GNU GPL, version 3 or later; the licenses of it and of the
libraries it uses are in licenses\\.

BlueWake is an unofficial project, not affiliated with or endorsed by
Nintendo. The Legend of Zelda: The Wind Waker is Nintendo's; play it from a
disc you own.
"""


# What every Windows 10 and 11 PC has; any other DLL a shipped binary imports
# must be in the download (the Visual C++ runtime included: a PC without the
# redistributable has none of it).
SYSTEM_DLLS = {
    "kernel32.dll", "user32.dll", "gdi32.dll", "advapi32.dll", "shell32.dll", "ole32.dll", "oleaut32.dll",
    "imm32.dll", "version.dll", "winmm.dll", "setupapi.dll", "ntdll.dll", "bcrypt.dll", "bcryptprimitives.dll",
    "comctl32.dll", "comdlg32.dll", "dxgi.dll", "d3d12.dll", "d3d11.dll", "dwmapi.dll", "uxtheme.dll", "hid.dll",
    "cfgmgr32.dll", "ws2_32.dll", "crypt32.dll", "psapi.dll", "dbghelp.dll", "shlwapi.dll", "userenv.dll",
    "secur32.dll", "ncrypt.dll", "powrprof.dll", "winhttp.dll", "iphlpapi.dll", "mfplat.dll", "avrt.dll",
}


def pe_imports(path):
    """The DLL names a PE file imports (its import directory)."""
    data = path.read_bytes()
    pe = int.from_bytes(data[0x3C:0x40], "little")
    if data[pe:pe + 4] != b"PE\0\0":
        return []
    sections = int.from_bytes(data[pe + 6:pe + 8], "little")
    optional = pe + 24
    size = int.from_bytes(data[pe + 20:pe + 22], "little")
    magic = int.from_bytes(data[optional:optional + 2], "little")
    directories = optional + (112 if magic == 0x20B else 96)
    import_rva = int.from_bytes(data[directories + 8:directories + 12], "little")
    table = optional + size
    spans = []
    for i in range(sections):
        s = table + 40 * i
        va, raw_size, raw = (int.from_bytes(data[s + o:s + o + 4], "little") for o in (12, 16, 20))
        virtual_size = int.from_bytes(data[s + 8:s + 12], "little")
        spans.append((va, max(virtual_size, raw_size), raw))

    def offset(rva):
        for va, length, raw in spans:
            if va <= rva < va + length:
                return raw + rva - va
        raise ValueError(f"{path.name}: RVA {rva:#x} outside its sections")

    names = []
    if import_rva == 0:
        return names
    entry = offset(import_rva)
    while True:
        name_rva = int.from_bytes(data[entry + 12:entry + 16], "little")
        if name_rva == 0:
            break
        start = offset(name_rva)
        names.append(data[start:data.index(b"\0", start)].decode("ascii"))
        entry += 20
    return names


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version", help="the release's version, e.g. 0.1.0")
    parser.add_argument("--app", type=Path, default=ROOT / "build/windows/BlueWake")
    parser.add_argument("--out", type=Path, default=ROOT / "build/windows/release")
    parser.add_argument("--nodtool", type=Path, default=ROOT / "build/tools/nodtool/bin/nodtool.exe")
    args = parser.parse_args()

    app = args.app
    for need in ("BlueWake.exe", "gGZLE01_recomp.dll", "BuilderProvenance.json"):
        if not (app / need).is_file():
            sys.exit(f"{app / need} is missing: run scripts/windows/build.py first")
    provenance = json.loads((app / "BuilderProvenance.json").read_text())
    if provenance.get("source_modified"):
        sys.exit("the app was built from a checkout with uncommitted changes: commit, rebuild, then package")
    if not args.nodtool.is_file():
        sys.exit(f"{args.nodtool} is missing: the builder makes it the first time it converts a .rvz")

    stage = args.out / NAME
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    for f in sorted(app.iterdir()):
        if f.is_file() and (APP_FILES.search(f.name) or f.name in ("initial_pipeline_cache.db",
                                                                    "BuilderProvenance.json")):
            shutil.copy2(f, stage / f.name)
    (stage / "dsp").mkdir()
    for name in ("dsp_rom.bin", "dsp_coef.bin"):
        shutil.copy2(app / "dsp" / name, stage / "dsp" / name)
    shutil.copy2(args.nodtool, stage / "nodtool.exe")
    (stage / "licenses").mkdir()
    for name, sources in LICENSES.items():
        source = next((s for s in sources if s.is_file()), None)
        if source is None:
            sys.exit(f"no license text for {name} (looked in {', '.join(str(s) for s in sources)})")
        shutil.copy2(source, stage / "licenses" / name)
    (stage / "README.txt").write_text(README.format(version=args.version).replace("\n", "\r\n"), newline="")

    # Nothing private, and nothing unexpected.
    files = sorted(p for p in stage.rglob("*") if p.is_file())
    bad = [p for p in files if PRIVATE.search(p.name) or "game" in p.relative_to(stage).parts[:-1]]
    if bad:
        sys.exit("refusing to package: " + ", ".join(str(p.relative_to(stage)) for p in bad))
    shipped = {p.name.lower() for p in stage.iterdir()}
    missing = sorted({f"{name} (for {p.name})" for p in files if APP_FILES.search(p.name) for name in pe_imports(p)
                      if name.lower() not in shipped and name.lower() not in SYSTEM_DLLS
                      and not name.lower().startswith(("api-ms-win-", "ext-ms-win-"))})
    if missing:
        sys.exit("refusing to package: these DLLs are imported but neither in the download nor part of Windows: "
                 + ", ".join(missing))

    zip_path = args.out / f"{NAME}-{args.version}-windows-x64.zip"
    zip_path.unlink(missing_ok=True)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p in files:
            z.write(p, f"{NAME}/{p.relative_to(stage).as_posix()}")
    digest = sha256(zip_path)
    (args.out / (zip_path.name + ".sha256")).write_text(f"{digest}  {zip_path.name}\n", newline="\n")
    total = sum(p.stat().st_size for p in files)
    print(f"{zip_path} ({zip_path.stat().st_size >> 20} MB; {len(files)} files, {total >> 20} MB unpacked)")
    print(f"sha256 {digest}")
    print(f"built from {provenance['source_commit']}; module {provenance['module_sha256']}")


if __name__ == "__main__":
    main()
