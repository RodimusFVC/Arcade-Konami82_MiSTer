#!/usr/bin/env python3
"""Generate MRAs for the Konami82 core straight from MAME konami/*.cpp.

Region placement matches rtl/boards/timeplt_board.sv; KONAMI* input macros are expanded with cpp (konamipt.h); images are copied as dumped.
Index 0 is the banked ROM store layout (bank_layout, rtl/konami82_board.sv): each set's window pages in 8K banks plus the
ROM bank map in index 1 bytes 64-95; the rbf needs MRAs from this generator (hand-made ones: copy a generated sibling's layout).
DIP switches and the input map come from the set's MAME INPUT_PORTS.

Release layout: a parent set (MAME parent 0) goes to <releases>/<Title>.mra with the
trailing parentheses dropped; a clone goes to
<releases>/_alternatives/_<Parent Title>/<Full Title>.mra. These carry no artwork. A set with MAME artwork also gets
the same tree under <releases>/_artwork/ with the artwork block (same file name: shares .nvm / .dip with the plain one).

Usage:
    gen_mra.py <driver.cpp[,driver.cpp...]> <releases_dir> [set ...]      (no sets: every supported set)
"""
import copy
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

MAME_VERSION = "0289"
RBF = "Konami82"
HISCORE_DAT = Path("/CybertronMD/Mame/plugins/hiscore/hiscore.dat")   # current file (user, 2026-09-27)
# hiscore.v header after START_WAIT: CHECK_WAIT 00FF, CHECK_HOLD 2, WRITE_HOLD 2, WRITE_REPEATCOUNT 1,
# WRITE_REPEATWAIT 1111, PAUSEPAD 0, CHANGEMASK 0
HISCORE_HEADER_TAIL = "00 FF 00 02 00 02 00 01 11 11 00 00"
# START_WAIT = last boot-time write to the hiscore.dat ranges, measured in MAME (write taps, 30 s, bytes rewritten
# every frame excluded), + 2 frames. Keyed by a reference set per distinct hiscore.dat layout.
# MAME frame at which every hiscore.dat range first holds its default start / end bytes (after the RAM test),
# measured 2026-10-17 with a per-frame sentinel log; START_WAIT = that + 2 frames. Keyed by one set per layout.
# rocnrope: 368 = the core's own table init (MAME 365). Its end bytes are 00 like cleared RAM, so a check before the
# init has finished matches part-way through it and the game then overwrites the restore (sim, hiscore.v).
HISCORE_INIT_FRAME = {"timeplt": 34, "psurge": 64, "pooyan": 65, "rocnrope": 368, "tutankhm": 61, "junofrst": 29,
                      "gyruss": 5, "venus": 5, "circusc": 316, "tp84": 245, "tp84b": 202}
CLK_HZ, FRAME_HZ = 49_152_000, 6_144_000 / (384 * 264)
# MAME artwork (rtl/art/artwork.sv, ported from the Centipede core): set -> games/mame-artwork/<zip> (its own, else its
# parent's), used as-is. The MRA sends a 2048-byte layout table (from the zip's default.lay) then each PNG behind an
# "AWI"+id marker on ioctl index 5. The OSD Artwork page picks the view (View n = the n-th view, listed in the MRA).
ART_DIR = Path(__file__).resolve().parent.parent / "games" / "mame-artwork"
ART_SCREEN_W = 512          # canvas pixels across the game screen (HDMI framebuffer); 2x native fits the DDR budget
ART_SCREEN_H = 512          # vertical games: canvas pixels down the (portrait) screen, same per-frame load as 512 across
ART_MAX_W = 1400            # widest canvas line: the HDMI scaler fetches one per output line; >~1450 shimmers at 1080p (HW 2026-10-24)
ART_BLOB_MAX = (1 << 26)    # PNG bytes + markers after the table: artwork.sv boff is 26 bits (64 MB DDR window)
ART_ROT = {"ROT0": 0, "ROT270": 1, "ROT90": 2}   # layout table byte 10
ART_NATIVE = (256, 224)     # every board's displayed raster (rtl/boards/*_board.sv raw_hblank / raw_vblank)
ART_NATIVE_BY = {}

# region -> (base in ioctl index 0, size taken); same bases on the Time Pilot and Pooyan boards
REGIONS = {
    "maincpu":               (0x00000, 0x08000),
    "timeplt_audio:tpsound": (0x08000, 0x04000),
    "tiles":                 (0x0C000, 0x04000),
    "sprites":               (0x10000, 0x04000),
    "proms":                 (0x14000, 0x00400),
}

# machine -> {region: (ioctl index, base, size) or None (not loaded)}
REGION_OVERRIDE = {
    "tutankhm": {"maincpu": "split"},              # rtl/boards/tutankhm_board.sv
    "gyruss": {                                     # rtl/boards/gyruss_board.sv + rtl/sound/gyruss_sound.sv
        "maincpu":  (0, 0x00000, 0x06000),
        "sub":      "split",
        "tiles":    (0, 0x0C000, 0x02000),
        "audio2":   (0, 0x0E000, 0x01000),
        "sprites":  (0, 0x10000, 0x08000),
        "audiocpu": (0, 0x18000, 0x06000),
        "proms":    (0, 0x20000, 0x00220),
    },
    "junofrst": {                                   # rtl/boards/tutankhm_board.sv + rtl/sound/junofrst_sound.sv
        "maincpu":  "split",
        "audiocpu": (0, 0x20000, 0x01000),
        "mcu":      (0, 0x21000, 0x01000),
        "blitrom":  (0, 0x24000, 0x06000),
    },
    "chkun": {                                      # TC8830F samples -> SDRAM (index 2, byte 0)
        "tc8830f": (2, 0x00000, 0x20000),
        "pld":     None,
    },
    "circusc": {                                    # rtl/boards/circusc_board.sv + rtl/sound/circusc_sound.sv
        "sprites":  "split",
        "tiles":    (0, 0x0C000, 0x04000),
        "audiocpu": (0, 0x10000, 0x04000),
        "maincpu":  (0, 0x10000, 0x10000),          # 6000-FFFF -> 0x16000
        "proms":    (0, 0x24000, 0x00220),
    },
    "tp84": {                                       # rtl/boards/tp84_board.sv + rtl/sound/tp84_sound.sv
        "cpu1":     (0, 0x10000, 0x10000),          # 8000-FFFF -> 0x18000
        "sub":      "split",
        "audiocpu": (0, 0x10000, 0x04000),
        "tiles":    (0, 0x0C000, 0x04000),
        "sprites":  (0, 0x00000, 0x08000),
        "proms":    (0, 0x22000, 0x00500),
    },
    "tp84b": {                                      # same board, I/O moved to 0000-1FFF
        "cpu1":     (0, 0x10000, 0x10000),          # 8000-FFFF -> 0x18000
        "sub":      "split",
        "audiocpu": (0, 0x10000, 0x04000),
        "tiles":    (0, 0x0C000, 0x04000),
        "sprites":  (0, 0x00000, 0x08000),
        "proms":    (0, 0x22000, 0x00500),
    },
    "rocnrope": {                                   # rtl/boards/rocnrope_board.sv
        "sprites":               (0, 0x00000, 0x08000),
        "timeplt_audio:tpsound": (0, 0x08000, 0x04000),   # every board: loading can't depend on the variant
        "tiles":                 (0, 0x0C000, 0x04000),
        "maincpu":               (0, 0x10000, 0x10000),
        "proms":                 (0, 0x20000, 0x00400),
        "pal_cpuvidbd":          None,
        "pals_daughterbd":       None,
    },
}
REGION_SPLIT = {
    "tutankhm": {"maincpu": [(0x0A000, 0x06000, 0x00000),      # A000-FFFF
                             (0x10000, 0x09000, 0x10000)]},    # banks 0-8 (9-15 empty)
    "gyruss":   {"sub":     [(0x0E000, 0x02000, 0x06000)]},    # E000-FFFF
    "tp84":     {"sub":     [(0x0E000, 0x02000, 0x20000)]},    # E000-FFFF, board-only
    "tp84b":    {"sub":     [(0x0E000, 0x02000, 0x20000)]},
    "circusc":  {"sprites": [(0x00000, 0x08000, 0x00000),      # shared block 0
                             (0x08000, 0x04000, 0x20000)]},    # board-only
    "junofrst": {"maincpu": [(0x0A000, 0x06000, 0x00000),      # A000-FFFF
                             (0x10000, 0x0C000, 0x10000)]},    # banks 0-11 (12-15 empty)
}
# ---- banked ROM store (rtl/konami82_board.sv). The addresses above are each image's window address, as the boards
# read it. The MRA's index 0 is NBANK 8K banks instead, loaded linearly (bank = ioctl addr[16:13]): every 8K page of a
# window that holds an image a channel reads is copied whole into a bank, and index 1 bytes 64-95 tell the core where
# (bytes 64-79: channel base bank, bank = base + window address[15:13] mod 16; bytes 80-95: per bank {port A owner,
# port B owner}, F = none). PROM images stay at their window address, read by the board's own loader.
BANK, NBANK = 0x2000, 15
MAP_AT = 64
# channel id -> (name, window base, window size); ids 0-5 read port B, 8-11 port A (port A also loads)
CHANNELS = {0: ("rom0", 0x00000, 0x8000), 1: ("rom1", 0x0C000, 0x4000), 2: ("rom2", 0x10000, 0x10000),
            3: ("rom3", 0x20000, 0x4000), 4: ("tpsound", 0x08000, 0x2000), 5: ("blitrom", 0x24000, 0x8000),
            8: ("rom0b", 0x00000, 0x8000), 9: ("rom1b", 0x0C000, 0x4000), 10: ("rom2b", 0x10000, 0x10000),
            11: ("jfmcu", 0x21000, 0x1000)}
# board variant -> {channel id: window range of the images it reads}, from the board RTL; a read elsewhere returns 0
_TP = {0: (0x00000, 0x08000), 1: (0x0C000, 0x10000), 2: (0x10000, 0x14000), 4: (0x08000, 0x0A000)}
CHANNEL_IMAGES = {
    0: _TP, 3: _TP, 4: _TP, 5: _TP, 1: _TP,                                      # Time Pilot board, Pooyan
    2: {0: (0x00000, 0x08000), 1: (0x0C000, 0x10000), 2: (0x10000, 0x20000), 4: (0x08000, 0x0A000)},   # Roc'n Rope
    6: {0: (0x00000, 0x06000), 2: (0x10000, 0x20000), 4: (0x08000, 0x0A000)},  # Tutankham
    7: {0: (0x00000, 0x06000), 2: (0x10000, 0x20000), 3: (0x20000, 0x21000), 11: (0x21000, 0x22000),
        5: (0x24000, 0x2A000)},                                                  # Juno First
    8: {0: (0x00000, 0x06000), 8: (0x06000, 0x08000), 1: (0x0C000, 0x0E000), 9: (0x0E000, 0x0F000),
        2: (0x10000, 0x18000), 10: (0x18000, 0x1E000)},                          # Gyruss
    9: {0: (0x00000, 0x08000), 1: (0x0C000, 0x10000), 2: (0x16000, 0x20000), 10: (0x10000, 0x14000),
        3: (0x20000, 0x24000)},                                                  # Circus Charlie
    10: {0: (0x00000, 0x08000), 8: (0x00000, 0x08000), 1: (0x0C000, 0x10000), 2: (0x18000, 0x20000),
         10: (0x10000, 0x12000), 3: (0x20000, 0x22000)},                         # Time Pilot '84 (sprites on both ports)
}
CHANNEL_IMAGES[11] = CHANNEL_IMAGES[10]
# board variant -> window ranges its PROM loaders take straight from index 0 (rtl/boards/*: load_prom)
_TP_PROM = [(0x14000, 0x14400)]
PROM_WINDOWS = {0: _TP_PROM, 3: _TP_PROM, 4: _TP_PROM, 5: _TP_PROM, 1: _TP_PROM, 2: [(0x20000, 0x20400)], 6: [], 7: [],
                8: [(0x20000, 0x20400)], 9: [(0x24000, 0x24400)], 10: [(0x22000, 0x22800)], 11: [(0x22000, 0x22800)]}

# (machine, region) whose images may be cut to the board window: bikkuric tiles = 2 identical 16K halves,
# 10-bit codes reach only the first (MAME ROM comment "1st and 2nd identical")
REGION_TRUNCATE = {("bikkuric", "tiles")}
IGNORED_REGIONS = set()

# (machine config, init) pairs the board implements, -> board variant byte
SUPPORTED = {
    ("timeplt", "empty_init"): 0,
    ("pooyan", "empty_init"): 1,
    ("rocnrope", "init_rocnrope"): 2,
    ("rocnrope", "empty_init"): 2,
    ("psurge", "empty_init"): 3,
    ("bikkuric", "empty_init"): 4,
    ("chkun", "empty_init"): 5,
    ("tutankhm", "empty_init"): 6,
    ("junofrst", "empty_init"): 7,
    ("gyruss", "empty_init"): 8,
    ("circusc", "empty_init"): 9,
    ("tp84", "empty_init"): 10,
    ("tp84b", "empty_init"): 11,
}

BOARD_FILE = {0: "rtl/boards/timeplt_board.sv", 3: "rtl/boards/timeplt_board.sv", 4: "rtl/boards/timeplt_board.sv",
              5: "rtl/boards/timeplt_board.sv", 1: "rtl/boards/pooyan_board.sv", 2: "rtl/boards/rocnrope_board.sv",
              6: "rtl/boards/tutankhm_board.sv", 7: "rtl/boards/tutankhm_board.sv",
              8: "rtl/boards/gyruss_board.sv", 9: "rtl/boards/circusc_board.sv",
              10: "rtl/boards/tp84_board.sv", 11: "rtl/boards/tp84_board.sv"}

# init -> (index 1 byte 2 CPU ROM decode, unused)
DECODE = {"init_rocnrope": (0x01, 0)}               # rocnrope_board: byte 0x703D patched on read

F_4WAY, F_WIDE, F_IMPULSE, F_VERT, F_ROT90 = 0x01, 0x02, 0x04, 0x10, 0x80
WIDE_INITS, WIDE_MACHINES = set(), set()
# index 1 byte 3 board flags: [0] IN1 controls follow IN0 in upright (MAME ladybug_p2_control_r)
F2_P2_FOLLOWS_P1 = 0x01
# PORT_CUSTOM_MEMBER handler -> port whose bits it returns
CUSTOM_PORTS = {}

# MAME state class -> board variant override
STATE_VARIANT = {}
# port order on the board: index 1 idle bytes 4-9, DIP selectors 10-15, input map bytes 16-63.
# Only ports carrying DIPs go in <switches> (bytes 0.., in port order): Main_MiSTer builds the default with
# 32-bit int shifts (mra_loader.cpp: binary[i] << (i * 8)), so only bytes 0-2 (and a byte 3 < 0x80) survive.
PORTS = [("IN0",), ("IN1",), ("IN2",), ("DSW0",), ("DSW1",), ("COIN",)]   # first name present wins
PORTS_BY_MACHINE = {"rocnrope": [("SYSTEM",), ("P1",), ("P2",), ("DSW1",), ("DSW2",), ("DSW3",)],
                    "tutankhm": [("IN0",), ("IN1",), ("IN2",), ("DSW1",), ("DSW2",), ("COIN",)],
                    "junofrst": [("SYSTEM",), ("P1",), ("P2",), ("DSW1",), ("DSW2",), ("COIN",)],
                    "gyruss":   [("SYSTEM",), ("P1",), ("P2",), ("DSW1",), ("DSW2",), ("DSW3",)],
                    "circusc":  [("SYSTEM",), ("P1",), ("P2",), ("DSW1",), ("DSW2",), ("DSW3",)],
                    "tp84":     [("SYSTEM",), ("P1",), ("P2",), ("DSW1",), ("DSW2",), ("DSW3",)],
                    "tp84b":    [("SYSTEM",), ("P1",), ("P2",), ("DSW1",), ("DSW2",), ("DSW3",)]}
PORT_REWRITE = {}

# control ids (Arcade-Konami82.sv)
CTL = {("JOYSTICK_UP", 1): 1, ("JOYSTICK_DOWN", 1): 2, ("JOYSTICK_LEFT", 1): 3, ("JOYSTICK_RIGHT", 1): 4,
       ("BUTTON1", 1): 5, ("BUTTON2", 1): 6, ("BUTTON3", 1): 7, ("BUTTON4", 1): 8,
       ("JOYSTICK_UP", 2): 9, ("JOYSTICK_DOWN", 2): 10, ("JOYSTICK_LEFT", 2): 11, ("JOYSTICK_RIGHT", 2): 12,
       ("BUTTON1", 2): 13, ("BUTTON2", 2): 14, ("BUTTON3", 2): 15, ("BUTTON4", 2): 16,
       ("BUTTON5", 1): 32, ("BUTTON6", 1): 33, ("BUTTON5", 2): 34, ("BUTTON6", 2): 35,
       ("COIN1", 0): 17, ("COIN2", 0): 18, ("START1", 0): 19, ("START2", 0): 20,
       ("GAMBLE_KEYOUT", 0): 33,                     # payout key (Bikkuri Card, Chance Kun) on P1 Btn 6
       ("TILT", 0): 21, ("SERVICE1", 0): 22, ("SERVICE2", 0): 22, ("SERVICE", 0): 22, ("COIN3", 0): 23,
       # twin stick: left stick = movement ids, right stick = right analog stick or Btn 3-6 (Arcade-Konami82.sv)
       **{(f"JOYSTICKLEFT_{d}", pl): b + o for pl, b in ((1, 0), (2, 8)) for d, o in (("UP", 1), ("DOWN", 2), ("LEFT", 3), ("RIGHT", 4))},
       **{(f"JOYSTICKRIGHT_{d}", pl): b + o for pl, b in ((1, 38), (2, 42)) for d, o in (("RIGHT", 0), ("LEFT", 1), ("DOWN", 2), ("UP", 3))}}
TWIN_IDS = range(38, 50)
# per-machine control overrides: Tutankham fires on A/B (or the right stick), Flash Bomb on X
CTL_BY_MACHINE = {"tutankhm": {("JOYSTICKRIGHT_RIGHT", 1): 46, ("JOYSTICKRIGHT_LEFT", 1): 47,
                               ("JOYSTICKRIGHT_RIGHT", 2): 48, ("JOYSTICKRIGHT_LEFT", 2): 49,
                               ("BUTTON2", 1): 7, ("BUTTON2", 2): 15}}
BUTTONS_BY_MACHINE = {"tutankhm": {1: "Fire Right", 2: "Fire Left", 3: "Flash Bomb"},
                      "junofrst": {1: "Fire", 2: "Warp", 3: "Button 3"}}   # manual: FIRE / WARP
TRACKBALL = {"TRACKBALL_X": 24, "TRACKBALL_Y": 28}   # ids 24-27 / 28-31 = counter bits 0-3
IGNORED_TYPES = {"UNUSED", "UNKNOWN"}
WORKING_HERE = set()
RACK_HOLD, RACK_TOGGLE = 36, 37                     # Rack Test cheat button (no default pad mapping)

SERIES_BY_PARENT = {"timeplt": ("Time Pilot", "Shooter"), "pooyan": ("Pooyan", "Shooter"), "rocnrope": ("Roc'n Rope", "Platform"),
                    "tutankhm": ("Tutankham", "Maze"), "junofrst": ("Juno First", "Shooter"),
                    "gyruss": ("Gyruss", "Shooter"), "circusc": ("Circus Charlie", "Platform"),
                    "tp84": ("Time Pilot '84", "Shooter")}
REGION_WORDS = [("US", "US"), ("Japan", "Japan"), ("Spanish", "Spain"), ("Italian", "Italy"), ("French", "France"),
                ("Brazil", "Brazil"), ("Argentina", "Argentina"), ("Greek", "Greece"), ("Hungarian", "Hungary")]

# ---------------------------------------------------------------- parsing

GAME_RE = re.compile(r'^GAME\(\s*([\w?]+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(ROT\d+),\s*"([^"]*)",\s*"([^"]*)",\s*([^)]*)\)', re.M)
LOAD16_RE = re.compile(r'ROM_LOAD16_BYTE\(\s*"([^"]+)",\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*CRC\(([0-9a-fA-F]+)\)')
LOAD_RE = re.compile(r'ROM_LOAD\(\s*"([^"]+)",\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*(?:BAD_DUMP\s+)?CRC\(([0-9a-fA-F]+)\)')
CONT_RE = re.compile(r'ROM_CONTINUE\(\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\s*\)')
NIB_RE = re.compile(r'ROM_LOAD_NIB_(LOW|HIGH)\s*\(\s*"([^"]+)",\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*CRC\(([0-9a-fA-F]+)\)')
RELOAD_RE = re.compile(r'ROM_RELOAD\(\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\s*\)')
FILL_RE = re.compile(r'ROM_FILL\(\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\s*\)')
COPY_RE = re.compile(r'ROM_COPY\(\s*"([^"]+)",\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\s*\)')
REGION_RE = re.compile(r'ROM_REGION(?:16_BE)?\(\s*(0x[0-9a-fA-F]+),\s*"([^"]+)"')
MACRO_RE = re.compile(r'\b(PORT_\w+|INPUT_PORTS_\w+)\b(\s*\(((?:[^()"]|"[^"]*"|\([^()]*\))*)\))?')


def parse_games(src):
    games = {}
    for m in GAME_RE.finditer(src):
        year, name, parent, machine, inputs, state, init, rot, manuf, desc, flags = m.groups()
        games[name] = dict(year=year, name=name, parent=None if parent == "0" else parent,
                           machine=machine, inputs=inputs, state=state, init=init, rot=rot, manuf=manuf, desc=desc,
                           working="MACHINE_NOT_WORKING" not in flags)
    return games


def parse_roms(src, setname):
    m = re.search(r'ROM_START\(\s*%s\s*\)(.*?)ROM_END' % re.escape(setname), src, re.S)
    if not m:
        raise SystemExit(f"ROM_START({setname}) not found")
    segs, region, rsize, last = [], None, 0, None
    for line in m.group(1).splitlines():
        line = line.split("//")[0]
        if "NO_DUMP" in line:
            continue                                   # never dumped; MAME runs without it
        if (r := REGION_RE.search(line)):
            region, rsize, last = r.group(2), int(r.group(1), 16), None
        elif (l := LOAD_RE.search(line)):
            name, off, length, crc = l.group(1), int(l.group(2), 16), int(l.group(3), 16), l.group(4).lower()
            last = dict(name=name, crc=crc, src=0, dst=off, len=length, flen=length, region=region, rsize=rsize)
            segs.append(last)
        elif (l := LOAD16_RE.search(line)):
            # ROM_LOAD16_BYTE (big-endian region): even offsets = high byte plane, odd = low byte plane
            name, off, length, crc = l.group(1), int(l.group(2), 16), int(l.group(3), 16), l.group(4).lower()
            last = dict(name=name, crc=crc, src=0, dst=off >> 1, len=length, flen=length,
                        region=f"{region}_{'lo' if off & 1 else 'hi'}", rsize=rsize // 2)
            segs.append(last)
        elif (c := CONT_RE.search(line)):
            off, length = int(c.group(1), 16), int(c.group(2), 16)
            nxt = dict(last, src=last["src"] + last["len"], dst=off, len=length)
            segs.append(nxt)
            last = nxt
        elif (n := NIB_RE.search(line)):
            # ROM_LOAD_NIB_LOW / _HIGH: two 4-bit PROMs sharing one byte; each gets its own slot, merged in the core
            half, name, off, length, crc = n.group(1), n.group(2), int(n.group(3), 16), int(n.group(4), 16), n.group(5).lower()
            last = dict(name=name, crc=crc, src=0, dst=off, len=length, flen=length,
                        region=f"{region}_n{'lo' if half == 'LOW' else 'hi'}", rsize=length)
            segs.append(last)
        elif (r := RELOAD_RE.search(line)):
            # ROM_RELOAD: the previous file loaded again at another offset
            base = next(s for s in reversed(segs) if s["name"] == last["name"] and s["src"] == 0)
            last = dict(base, dst=int(r.group(1), 16), len=int(r.group(2), 16))
            segs.append(last)
        elif (f := FILL_RE.search(line)):
            off, length, val = int(f.group(1), 16), int(f.group(2), 16), int(f.group(3), 16)
            segs.append(dict(name=None, crc=None, fill=val, src=0, dst=off, len=length, region=region, rsize=rsize))
            last = None
        elif (c := COPY_RE.search(line)):
            # ROM_COPY re-reads bytes already loaded into a region: slice the file loads that cover the source range
            sreg, sofs, dofs, length = c.group(1), int(c.group(2), 16), int(c.group(3), 16), int(c.group(4), 16)
            covered = 0
            for s in [s for s in segs if s["region"] == sreg]:
                lo, hi = max(s["dst"], sofs), min(s["dst"] + s["len"], sofs + length)
                if lo < hi:
                    segs.append(dict(s, src=s["src"] + lo - s["dst"], dst=dofs + lo - sofs, len=hi - lo,
                                     region=region, rsize=rsize))
                    covered += hi - lo
            if covered != length:
                raise SystemExit(f"{setname}: ROM_COPY source not fully loaded: {line.strip()}")
            last = None
        elif "ROM_" in line and any(k in line for k in ("ROM_LOAD", "ROM_COPY", "ROM_FILL", "ROM_RELOAD")):
            raise SystemExit(f"{setname}: unhandled ROM statement: {line.strip()}")
    return segs


def def_str(s):
    s = s.strip()
    m = re.fullmatch(r'DEF_STR\(\s*(\w+)\s*\)', s)
    if not m:
        return s.strip('"')
    w = m.group(1)
    c = re.fullmatch(r'(\d+)C_(\d+)C', w)
    if c:
        return f"{c.group(1)}C/{c.group(2)}C"
    return w.replace("_", " ")


def idle_level(arg, mask):
    """Released level from an IP_ACTIVE_LOW / IP_ACTIVE_HIGH keyword or a numeric default."""
    if arg == "IP_ACTIVE_LOW":
        return mask
    if arg == "IP_ACTIVE_HIGH":
        return 0
    return int(arg, 0) & mask


def split_args(a):
    out, depth, cur, q = [], 0, "", False
    for ch in a:
        if ch == '"':
            q = not q
        if not q and ch == "(":
            depth += 1
        elif not q and ch == ")":
            depth -= 1
        if ch == "," and depth == 0 and not q:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def port_default(fields):
    """Port value with every field at its default (conditional fields left idle): artwork element states."""
    level = 0xFF
    for f in fields:
        if "cond" not in f:
            level = (level & ~f["mask"]) | (f["default"] & f["mask"])
    return level


def parse_inputs(src):
    """INPUT_PORTS name -> {tag: [field]}; field = dict(mask, kind, default, type, player, name, settings, fourway)."""
    blocks = {m.group(1): m.group(2) for m in re.finditer(
        r'INPUT_PORTS_START\(\s*(\w+)\s*\)(.*?)INPUT_PORTS_END', src, re.S)}
    cache = {}

    def build(name):
        if name in cache:
            return copy.deepcopy(cache[name])
        ports, cur, fld = {}, None, None
        body = "\n".join(l.split("//")[0] for l in blocks[name].splitlines())
        for m in MACRO_RE.finditer(body):
            mac, args = m.group(1), split_args(m.group(3) or "")
            if mac == "PORT_INCLUDE":
                ports.update(build(args[0]))
            elif mac in ("PORT_START", "PORT_MODIFY"):
                cur = args[0].strip('"')
                if mac == "PORT_START":
                    ports[cur] = []
                fld = None
            elif mac in ("PORT_BIT", "PORT_DIPNAME", "PORT_CONFNAME", "PORT_SERVICE", "PORT_SERVICE_DIPLOC", "PORT_SERVICE_NO_TOGGLE",
                         "PORT_DIPUNUSED", "PORT_DIPUNUSED_DIPLOC", "PORT_DIPUNKNOWN", "PORT_DIPUNKNOWN_DIPLOC"):
                mask = int(args[0], 0)
                ports[cur] = [f for f in ports[cur] if not (f["mask"] & mask)]
                if mac == "PORT_BIT":
                    low = args[1] == "IP_ACTIVE_LOW"
                    t = args[2].replace("IPT_", "")
                    if t in TRACKBALL:
                        low = False
                    fld = dict(mask=mask, kind="unused" if t in IGNORED_TYPES else "input",
                               default=mask if low else 0, type=t, player=1, name=None, settings=[], fourway=False)
                elif mac in ("PORT_DIPNAME", "PORT_CONFNAME"):
                    fld = dict(mask=mask, kind="dip", default=int(args[1], 0), name=def_str(args[2]), settings=[])
                elif mac in ("PORT_SERVICE", "PORT_SERVICE_DIPLOC"):
                    off = idle_level(args[1], mask)
                    on = off ^ mask
                    fld = dict(mask=mask, kind="dip", default=off, name="Service Mode", settings=[(off, "Off"), (on, "On")])
                elif mac == "PORT_SERVICE_NO_TOGGLE":
                    fld = dict(mask=mask, kind="input", default=idle_level(args[1], mask), type="SERVICE", player=0,
                               name=None, settings=[], fourway=False)
                else:
                    d = {"IP_ACTIVE_LOW": mask, "IP_ACTIVE_HIGH": 0}.get(args[1])
                    fld = dict(mask=mask, kind="unused", default=int(args[1], 0) if d is None else d)
                ports[cur].append(fld)
            elif mac in ("PORT_DIPSETTING", "PORT_CONFSETTING"):
                fld["settings"].append((int(args[0], 0), def_str(args[1])))
            elif mac == "PORT_PLAYER":
                fld["player"] = int(args[0])
            elif mac == "PORT_COCKTAIL":
                fld["player"] = 2
            elif mac == "PORT_4WAY":
                fld["fourway"] = True
            elif mac == "PORT_REVERSE":
                fld["reverse"] = True
            elif mac == "PORT_NAME":
                fld["name"] = args[0].strip('"')
            elif mac == "PORT_IMPULSE":
                fld["impulse"] = True
            elif mac == "PORT_TOGGLE":
                fld["toggle"] = True
            elif mac == "PORT_2WAY":
                fld["twoway"] = True
            elif mac in ("PORT_DIPLOCATION", "PORT_CODE", "PORT_8WAY", "PORT_CONDITION",
                         "PORT_SENSITIVITY", "PORT_KEYDELTA", "PORT_MINMAX", "PORT_READ_LINE_DEVICE_MEMBER",
                         "PORT_CHANGED_MEMBER", "PORT_WRITE_LINE_DEVICE_MEMBER"):
                pass
            elif mac == "PORT_CUSTOM_MEMBER":
                fld["custom"] = re.sub(r".*::", "", args[0]).rstrip(")")
            else:
                raise SystemExit(f"INPUT_PORTS({name}): unhandled {mac}")
        cache[name] = ports
        return copy.deepcopy(ports)

    return build


def place(segs, setname, machine):
    """-> {ioctl index: [segment with addr]}"""
    over = REGION_OVERRIDE.get(machine, {})
    out = {}
    for s in segs:
        if s["region"] in over:
            if over[s["region"]] is None:
                continue
            if over[s["region"]] == "split":
                lo, ln, bs = next(t for t in REGION_SPLIT[machine][s["region"]] if t[0] <= s["dst"] < t[0] + t[1])
                if s["dst"] + s["len"] > lo + ln:
                    raise SystemExit(f"{setname}: {s['name']} crosses a split of {s['region']}")
                s = dict(s, dst=s["dst"] - lo)
                idx, base, size = 0, bs, ln
            else:
                idx, base, size = over[s["region"]]
        elif s["region"] in IGNORED_REGIONS:
            continue
        elif s["region"] not in REGIONS:
            raise SystemExit(f"{setname}: unmapped region {s['region']}")
        else:
            idx, (base, size) = 0, REGIONS[s["region"]]
        if s["dst"] >= size:
            continue                                   # e.g. the namco timing PROM
        if s["dst"] + s["len"] > size:
            if (machine, s["region"]) not in REGION_TRUNCATE:
                raise SystemExit(f"{setname}: {s['name']} overruns {s['region']}")
            s = dict(s, len=size - s["dst"])
        a, e = base + s["dst"], base + s["dst"] + s["len"]
        kept = []
        for o in out.get(idx, []):                                  # later loads, copies and fills overwrite earlier bytes
            oe = o["addr"] + o["len"]
            if oe <= a or o["addr"] >= e:
                kept.append(o)
                continue
            if o["addr"] < a:
                kept.append(dict(o, len=a - o["addr"]))
            if oe > e:
                kept.append(dict(o, addr=e, src=o["src"] + e - o["addr"], len=oe - e))
        out[idx] = kept + [dict(s, addr=a)]
    for idx in out:
        out[idx].sort(key=lambda s: s["addr"])
        for a, b in zip(out[idx], out[idx][1:]):
            assert a["addr"] + a["len"] <= b["addr"], f"{setname}: overlap {a['name']} / {b['name']}"
    return out


def bank_layout(segs, setname, variant):
    """index 0 window layout (place()) -> (bank layout segments, index 1 bytes 64-95); see CHANNELS"""
    images, proms = CHANNEL_IMAGES[variant], PROM_WINDOWS[variant]
    for s in segs:
        e = s["addr"] + s["len"]
        if not any(lo <= s["addr"] and e <= hi for lo, hi in list(images.values()) + proms):
            raise SystemExit(f"{setname}: {s.get('name')} at {s['addr']:#x} is read by no channel or PROM loader")

    def page_slice(c, p):
        _, wb, ws = CHANNELS[c]
        return wb + p * BANK, min(wb + (p + 1) * BANK, wb + ws)

    # pages of each channel's window holding its images; channels sharing a page share a bank (one per port)
    used = {}
    for c, (lo, hi) in sorted(images.items()):
        pages = [p for p in range((CHANNELS[c][2] + BANK - 1) // BANK)
                 if any(max(s["addr"], lo, page_slice(c, p)[0]) < min(s["addr"] + s["len"], hi, page_slice(c, p)[1])
                        for s in segs)]
        if pages:
            used[c] = pages
    groups = []                                        # [channels, pages] with one base bank
    for c in sorted(used):
        win = CHANNELS[c][1:]
        g = next((g for g in groups if CHANNELS[g[0][0]][1:] == win and set(g[1]) & set(used[c])), None)
        if g:
            g[0].append(c)
            g[1] = sorted(set(g[1]) | set(used[c]))
        else:
            groups.append([[c], list(used[c])])
    for chans, _ in groups:
        if len({c & 8 for c in chans}) != len(chans):
            raise SystemExit(f"{setname}: channels {chans} share a bank port")
    reserved = {b for b in range(NBANK) for s in segs
                if not any(lo <= s["addr"] < hi for lo, hi in images.values())
                and s["addr"] < (b + 1) * BANK and s["addr"] + s["len"] > b * BANK}

    def fit(i, taken):
        if i == len(groups):
            return []
        pages = groups[i][1]
        for b0 in range(NBANK - (pages[-1] - pages[0])):
            banks = [b0 + p - pages[0] for p in pages]
            if not (set(banks) & (taken | reserved)):
                rest = fit(i + 1, taken | set(banks))
                if rest is not None:
                    return [b0 - pages[0]] + rest
        return None

    groups.sort(key=lambda g: (-len(g[1]), g[0][0]))
    bases = fit(0, set())
    if bases is None:
        raise SystemExit(f"{setname}: images need more than {NBANK} banks of {BANK:#x}")
    out, rmap = [], [0] * 16 + [0xFF] * 16
    for (chans, pages), base in zip(groups, bases):
        for c in chans:
            rmap[c] = base & 0x0F
        for p in pages:
            b = base + p
            for c in chans:
                if p in used[c]:
                    sh = 4 if c & 8 else 0
                    rmap[16 + b] = rmap[16 + b] & ~(0x0F << sh) | (c & 0x0F) << sh
            lo, hi = page_slice(chans[0], p)
            for s in segs:                               # the page's window bytes, all images in it
                a, e = max(s["addr"], lo), min(s["addr"] + s["len"], hi)
                if a < e:
                    t = dict(s, addr=b * BANK + a - lo, len=e - a)
                    if s.get("fill") is None:
                        t["src"] = s["src"] + a - s["addr"]
                    out.append(t)
    out.sort(key=lambda s: s["addr"])
    filled, pos = [], None                               # zero every byte of a used bank the window left unwritten
    banks = sorted({s["addr"] // BANK for s in out})
    for b in banks:
        pos = b * BANK
        for s in [s for s in out if s["addr"] // BANK == b]:
            if s["addr"] > pos:
                filled.append(dict(name=None, crc=None, fill=0, src=0, addr=pos, len=s["addr"] - pos))
            filled.append(s)
            pos = s["addr"] + s["len"]
        if pos < (b + 1) * BANK:
            filled.append(dict(name=None, crc=None, fill=0, src=0, addr=pos, len=(b + 1) * BANK - pos))
    for s in segs:                                       # PROMs stay at their window address, above or beside the banks
        if not any(lo <= s["addr"] < hi for lo, hi in images.values()):
            if any(s["addr"] < (b + 1) * BANK and s["addr"] + s["len"] > b * BANK for b in banks):
                raise SystemExit(f"{setname}: {s.get('name')} at {s['addr']:#x} lands in a used bank")
            filled.append(s)
    filled.sort(key=lambda s: s["addr"])
    for a, b in zip(filled, filled[1:]):
        assert a["addr"] + a["len"] <= b["addr"], f"{setname}: bank layout overlap {a.get('name')} / {b.get('name')}"
    return filled, rmap


def whole_file(seg, segs):
    """True when this segment is the file's only load (no ROM_CONTINUE pieces)."""
    return (sum(1 for s in segs if s["name"] == seg["name"] and s["crc"] == seg["crc"]) == 1 and seg["src"] == 0
            and seg["len"] == seg["flen"])

# ---------------------------------------------------------------- inputs -> MRA

def input_config(g, ports):
    """-> (idle bytes, dip list, input map, 4-way, P1 button names, trackball reverse flags, coin impulse)."""
    idle, dips, imap, fourway, buttons, tb_rev, impulse = [], [], [0] * 48, False, {}, 0, False
    port_list = PORTS_BY_MACHINE.get(g["machine"], PORTS)
    ctl = {**CTL, **CTL_BY_MACHINE.get(g["machine"], {})}
    tags = [next((n for n in names if n in ports), names[0]) for names in port_list]
    dip_ports = [p for p, t in enumerate(tags) if any(f["kind"] == "dip" for f in ports.get(t, []))]
    if len(dip_ports) > 3:
        raise SystemExit(f'{g["name"]}: {len(dip_ports)} DIP ports; Main_MiSTer only keeps 3 default bytes reliably')
    for p, names in enumerate(port_list):
        tag = next((n for n in names if n in ports), names[0])
        fields = ports.get(tag)
        if fields is None:
            idle.append(0xFF)
            continue
        level = 0xFF
        for f in fields:
            level = (level & ~f["mask"]) | (f["default"] & f["mask"])
            if f["kind"] == "dip":
                lo = (f["mask"] & -f["mask"]).bit_length() - 1
                hi = f["mask"].bit_length() - 1
                if f["mask"] != ((1 << (hi + 1)) - (1 << lo)):
                    raise SystemExit(f'{g["name"]}: non-contiguous DIP {f["name"]} mask {f["mask"]:#x}')
                vals = [v >> lo for v, _ in f["settings"]]
                ids = ",".join(n.replace(",", ";") for _, n in f["settings"])
                d = dip_ports.index(p) * 8
                bits = f"{d + lo}" if lo == hi else f"{d + lo},{d + hi}"
                seq = vals == list(range(len(vals))) and len(vals) == 1 << (hi - lo + 1)
                dips.append((f["name"], bits, ids, None if seq else ",".join(str(v) for v in vals)))
                if f["name"].startswith("Rack Test") and lo == hi:
                    imap[p * 8 + lo] = RACK_TOGGLE if f.get("toggle") else RACK_HOLD   # button flips the DIP
            elif f["kind"] == "input":
                t, pl = f["type"], f["player"]
                if t == "CUSTOM" and f["mask"] == 0x0F and tag in ("IN0", "IN1") and ports.get("P1"):
                    # Club Pac-Man: P1 / P2 joysticks multiplexed onto bits 0-3 by latch Q5 / Q4 (the board gates them)
                    for pf in ports["P1" if tag == "IN0" else "P2"]:
                        if pf["kind"] == "input":
                            imap[p * 8 + pf["mask"].bit_length() - 1] = ctl[(pf["type"], pf["player"])]
                            fourway |= pf["fourway"]
                    continue
                if t == "CUSTOM" and f.get("custom") in CUSTOM_PORTS:
                    # handler returns another port's bits: map them in place, with that port's idle levels
                    for sf in ports[CUSTOM_PORTS[f["custom"]]]:
                        bits = sf["mask"] & f["mask"]
                        if not bits:
                            continue
                        level = (level & ~bits) | (sf["default"] & bits)
                        if sf["kind"] == "input":
                            imap[p * 8 + sf["mask"].bit_length() - 1] = ctl[(sf["type"], sf["player"])]
                            fourway |= sf["fourway"]
                    continue
                if t == "CUSTOM":
                    continue                           # no handler: a fixed level, already in the idle byte
                if t in TRACKBALL:
                    if f["mask"] != 0x0F:
                        raise SystemExit(f'{g["name"]}: trackball mask {f["mask"]:#x} in {tag}')
                    for b in range(4):
                        imap[p * 8 + b] = TRACKBALL[t] + b
                    tb_rev |= (1 if t == "TRACKBALL_X" else 2) if f.get("reverse") else 0
                    continue
                key = (t, pl if t.startswith(("JOYSTICK", "BUTTON")) else 0)
                if key not in ctl:
                    raise SystemExit(f'{g["name"]}: unmapped input {t} player {pl} in {tag}')
                if f["mask"] & (f["mask"] - 1):
                    raise SystemExit(f'{g["name"]}: multi-bit input {t} in {tag}')
                imap[p * 8 + f["mask"].bit_length() - 1] = ctl[key]
                impulse |= t.startswith("COIN") and f.get("impulse", False)
                fourway |= f["fourway"]
                if t.startswith("BUTTON") and pl == 1:
                    buttons[int(t[6:])] = f["name"] or ("Fire" if t == "BUTTON1" else f"Button {t[6:]}")
                if t == "GAMBLE_KEYOUT":
                    buttons[6] = "Key Out"
        idle.append(level & 0xFF)
    input_config.dip_ports = dip_ports
    return idle, dips, imap, fourway, buttons, tb_rev, impulse


def parse_hiscores(path):
    """hiscore.dat -> {set: [entry lines]}; sets listed together share the entry lines below them."""
    out, names, body = {}, [], False
    for line in path.read_text(encoding="latin-1").splitlines():
        line = line.strip()
        if not line or line.startswith(";"):
            names, body = ([], False) if not line else (names, body)
            continue
        if line.endswith(":"):
            if body:
                names, body = [], False
            names.append(line[:-1])
        elif line.startswith("@"):
            for n in names:
                out.setdefault(n, []).append(line)
            body = True
    return out


HISCORES = parse_hiscores(HISCORE_DAT) if HISCORE_DAT.exists() else {}


def hiscore_xml(g):
    lines = HISCORES.get(g["name"])
    if not lines:
        return ""
    ents = []
    for line in lines:
        if line.startswith("@delay="):
            continue                                   # load delay directive: START_WAIT is measured instead
        f = line.split(",")
        if f[0] not in ("@:maincpu", "@:cpu1") or f[1] != "program":     # tp84 names its main CPU cpu1
            raise SystemExit(f'{g["name"]}: unsupported hiscore.dat line {line}')
        ents.append((int(f[2], 16), int(f[3], 16), int(f[4], 16), int(f[5], 16)))
    rows = "\n".join(f"            {a >> 24 & 0xFF:02X} {a >> 16 & 0xFF:02X} {a >> 8 & 0xFF:02X} {a & 0xFF:02X} "
                      f"{n >> 8:02X} {n & 0xFF:02X} {s:02X} {e:02X}" for a, n, s, e in ents)
    total = sum(n for _, n, _, _ in ents)
    ref = next((k for k in HISCORE_INIT_FRAME if HISCORES.get(k) == lines), None)
    if ref is None:
        print(f'{g["name"]}: no measured hiscore init frame yet, hiscore omitted')
        return ""
    wait = round((HISCORE_INIT_FRAME[ref] + 2) / FRAME_HZ * CLK_HZ)
    header = " ".join(f"{b:02X}" for b in wait.to_bytes(4, "big")) + " " + HISCORE_HEADER_TAIL
    return f"""
    <!-- Index 3: hiscore config (MAME hiscore.dat), index 4: saved scores -->
    <rom index="3" md5="none">
        <part>
            {header}
{rows}
        </part>
    </rom>
    <rom index="4"></rom>
    <nvram index="4" size="{total}"></nvram>
"""


def art_table(zipname, rot="ROT0", port_defaults=None):
    """MAME default.lay -> (2048-byte table, [png names], [view names]); see rtl/art/artwork.sv for the format.
    rot = the set's orientation: the layout is in screen orientation (portrait for ROT90 / ROT270), the core's
    picture is the unrotated raster (ART_NATIVE). Views keep the screen and canvas on even pixels both
    ways, so the core can also draw them turned 90 (OSD Orientation Horz). port_defaults = {port tag: default value}
    for input-driven elements.
    Layer record: op, image (rect: R), flags, colour alpha, X, Y, W, H, X2 (rect: G, B), W2.
    Flags: [0] flipx, [1] alpha from mask, [3:2] kind (OSD toggle: 0 backdrop, 1 overlay, 2 bezel, 3 control panel /
    marquee), [4] bezel-off rect, [5] side art, [6] rect, [7] flipy. A mask layer's colour alpha scales the mask (MAME alphafile)."""
    import struct, zipfile
    z = zipfile.ZipFile(ART_DIR / f"{zipname}.zip")
    native = ART_NATIVE_BY.get(zipname, ART_NATIVE)
    lay = ET.fromstring(z.read("default.lay"))

    def png_size(name):
        d = z.read(name)
        return struct.unpack(">II", d[16:24])

    def rgba(c):
        return [float(c.get(k, "1")) if c is not None else 1.0 for k in ("red", "green", "blue", "alpha")]

    def _bounds(e):
        b = e.find("bounds")
        if b is None:
            return None
        if b.get("left") is not None:
            return tuple(float(b.get(k)) for k in ("left", "top", "right", "bottom"))
        x, y = float(b.get("x", "0")), float(b.get("y", "0"))
        return x, y, x + float(b.get("width")), y + float(b.get("height"))

    def bounds(n):
        b = _bounds(n)
        return None if b is None else (b[0], b[1], b[2] - b[0], b[3] - b[1])

    # element -> ("img", [image nodes], defstate) | ("rects", [(x0, y0, x1, y1 in element units 0-1, rgba)])
    elems = {}
    for e in lay.findall("element"):
        name, kids = e.get("name"), list(e)
        imgs = [k for k in kids if k.tag == "image"]
        rects = [k for k in kids if k.tag == "rect"]
        if imgs and len(imgs) == len(kids):
            elems[name] = ("img", imgs, e.get("defstate", "0"))
        elif rects and len(rects) == len(kids):
            ib = [_bounds(r) or (0.0, 0.0, 1.0, 1.0) for r in rects]     # MAME default: the unit square
            ix0, iy0 = min(b[0] for b in ib), min(b[1] for b in ib)
            ix1, iy1 = max(b[2] for b in ib), max(b[3] for b in ib)
            elems[name] = ("rects", [((b[0] - ix0) / (ix1 - ix0), (b[1] - iy0) / (iy1 - iy0), (b[2] - ix0) / (ix1 - ix0),
                                      (b[3] - iy0) / (iy1 - iy0), rgba(r.find("color"))) for r, b in zip(rects, ib)])
        else:
            print(f"artwork {zipname}: element {name} is not plain images or rects, skipped")

    images, views, layers = [], [], []

    def img_id(name):
        if name not in images:
            images.append(name)
        return images.index(name)

    OP_MUL, OP_ADD, OP_ALPHA, OP_UNDER, OP_MASK = 0, 1, 2, 3, 4
    groups = {g.get("name"): g for g in lay.findall("group")}

    def flatten(node):
        # <group ref>: the group's items mapped from its bounds (or the union of its items) into the reference's bounds
        out = []
        for it in node:
            if it.tag == "group" and it.get("ref") in groups:
                inner = flatten(groups[it.get("ref")])
                gb = bounds(groups[it.get("ref")])
                if gb is None:
                    bs = [bounds(i) for i in inner]
                    x0, y0 = min(b[0] for b in bs), min(b[1] for b in bs)
                    gb = (x0, y0, max(b[0] + b[2] for b in bs) - x0, max(b[1] + b[3] for b in bs) - y0)
                tb = bounds(it) or gb
                kx, ky = tb[2] / gb[2], tb[3] / gb[3]
                for i in inner:
                    b = bounds(i)
                    c = copy.deepcopy(i)
                    for old_b in c.findall("bounds"):
                        c.remove(old_b)
                    ET.SubElement(c, "bounds", x=str(tb[0] + (b[0] - gb[0]) * kx), y=str(tb[1] + (b[1] - gb[1]) * ky),
                                  width=str(b[2] * kx), height=str(b[3] * ky))
                    out.append(c)
            elif it.tag != "group" and bounds(it) is not None:
                out.append(it)
        return out

    def state_of(it, el):
        """Element state as MAME shows it with the set's default inputs: inputraw = (port & mask) >> lsb,
        other input items 0 (not pressed), else the element's defstate (outputs are not driven)."""
        tag = it.get("inputtag")
        if not tag:
            return el[2]
        mask = int(it.get("inputmask", "0"), 0)
        if it.get("inputraw") not in ("1", "yes"):
            return "0"
        if port_defaults is None or tag.lstrip(":") not in port_defaults:
            print(f"artwork {zipname}: {it.get('ref')} input {tag} has no default here, defstate used")
            return el[2]
        return str((port_defaults[tag.lstrip(":")] & mask) >> ((mask & -mask).bit_length() - 1 if mask else 0))

    def flatten_v2(node, tr, col, coll):
        """MAME rendlay.cpp add_items: <element ref> / <screen> in document order; <group ref> mapped from the group's
        bounds onto the item's bounds, colour multiplied (a group's blend attribute is ignored by MAME); hidden
        collections dropped (MAME default visibility). -> [(tag, item node, (x0, y0, x1, y1), rgba, collection)]"""
        out = []
        for it in node:
            if it.tag == "collection":
                if it.get("visible", "yes") not in ("no", "0", "false"):
                    out += flatten_v2(it, tr, col, coll or it.get("name"))
            elif it.tag == "group":
                gn = groups[it.get("ref")]
                gb = _bounds(gn)
                if gb is None:
                    bs = [b for _, _, b, _, _ in flatten_v2(gn, lambda b: b, [1.0] * 4, None)]
                    gb = (min(b[0] for b in bs), min(b[1] for b in bs), max(b[2] for b in bs), max(b[3] for b in bs))
                ib = _bounds(it)
                if it.find("orientation") is not None:
                    print(f"artwork {zipname}: group {it.get('ref')} orientation not supported, drawn unrotated")

                def gtr(b, gb=gb, ib=ib, tr=tr):
                    if ib is None:
                        return tr(b)
                    sx, sy = (ib[2] - ib[0]) / (gb[2] - gb[0]), (ib[3] - ib[1]) / (gb[3] - gb[1])
                    return tr((ib[0] + (b[0] - gb[0]) * sx, ib[1] + (b[1] - gb[1]) * sy,
                               ib[0] + (b[2] - gb[0]) * sx, ib[1] + (b[3] - gb[1]) * sy))
                out += flatten_v2(gn, gtr, [a * b for a, b in zip(col, rgba(it.find("color")))], coll)
            elif it.tag in ("screen", "element") and _bounds(it) is not None:
                out.append((it.tag, it, tr(_bounds(it)), [a * b for a, b in zip(col, rgba(it.find("color")))], coll))
            elif it.tag in ("repeat", "param"):
                print(f"artwork {zipname}: view {v.get('name')}: <{it.tag}> not supported, skipped")
        return out

    LEGACY = ("backdrop", "overlay", "bezel", "cpanel", "marquee")
    for v in lay.findall("view"):
        # layer list: (op, kind, element name, (x, y, w, h), rgba, orientation node, state)
        fv = flatten(v)                 # <group ref> resolved
        if any(it.tag in LEGACY for it in fv):
            items = {k: [] for k in ("backdrop", "screen", "overlay", "bezel", "cpanel", "marquee")}
            for it in fv:
                if it.tag in items:
                    items[it.tag].append(it)
            if len(items["screen"]) != 1:
                print(f"artwork {zipname}: view {v.get('name')} needs exactly one screen, skipped")
                continue
            vb = bounds(v)
            if vb is None:      # union of every item
                bs = [bounds(i) for k in items for i in items[k]]
                x0, y0 = min(b[0] for b in bs), min(b[1] for b in bs)
                vb = (x0, y0, max(b[0] + b[2] for b in bs) - x0, max(b[1] + b[3] for b in bs) - y0)
            sb = bounds(items["screen"][0])
            if items["overlay"] or len(items["backdrop"]) <= 1:
                order = [(OP_MUL, "overlay"), (OP_ADD, "backdrop"), (OP_ALPHA, "bezel"), (OP_ALPHA, "cpanel"), (OP_ALPHA, "marquee")]
            else:
                order = [(OP_UNDER, "backdrop"), (OP_ALPHA, "bezel"), (OP_ALPHA, "cpanel"), (OP_ALPHA, "marquee")]
            seq = [(op, kind, it.get("element"), bounds(it), rgba(it.find("color")), it.find("orientation"), None)
                   for op, kind in order for it in items[kind]]
        else:
            # modern layout (element ref / collection / group): draw order = document order, element blend default
            # alpha; the screen draws opaque (BLENDMODE_NONE) unless blend="add". Before the screen: alpha = UNDER,
            # add = ADD; after it: alpha = ALPHA, add = ADD, multiply = MUL. OSD toggle kind from the collection name.
            flat = flatten_v2(v, lambda b: b, [1.0] * 4, None)
            scr = [i for i, f in enumerate(flat) if f[0] == "screen"]
            if len(scr) != 1:
                print(f"artwork {zipname}: view {v.get('name')} needs exactly one screen, skipped")
                continue
            si = scr[0]
            s0 = flat[si][2]
            sb = (s0[0], s0[1], s0[2] - s0[0], s0[3] - s0[1])
            vb = bounds(v)
            if vb is None:
                bs = [f[2] for f in flat]
                x0, y0 = min(b[0] for b in bs), min(b[1] for b in bs)
                vb = (x0, y0, max(b[2] for b in bs) - x0, max(b[3] for b in bs) - y0)
            if flat[si][1].get("blend") not in (None, "none", "alpha", "add"):
                print(f"artwork {zipname}: view {v.get('name')}: screen blend {flat[si][1].get('blend')} not supported")
            opaque = flat[si][1].get("blend") != "add"
            seq = []
            for i, (tag, it, b, col, coll) in enumerate(flat):
                if tag == "screen":
                    continue
                blend = it.get("blend", "alpha")
                if blend == "multiply" and i < si:
                    print(f"artwork {zipname}: {it.get('ref')} multiply under the screen not supported, skipped")
                    continue
                op = {"multiply": OP_MUL, "add": OP_ADD}.get(blend, OP_UNDER if i < si else OP_ALPHA)
                if i < si and opaque and b[0] < s0[2] and s0[0] < b[2] and b[1] < s0[3] and s0[1] < b[3]:
                    print(f"artwork {zipname}: {it.get('ref')} under an opaque screen: drawn under the game")
                cn = (coll or "").lower()
                kind = ("overlay" if "overlay" in cn else "backdrop" if "backdrop" in cn or "background" in cn else
                        "bezel" if "bezel" in cn else "cpanel" if "panel" in cn or "marquee" in cn else "side" if "side" in cn else "art" if cn else
                        "overlay" if op == OP_MUL else "backdrop" if i < si or op == OP_ADD else "art")
                el = elems.get(it.get("ref"))
                seq.append((op, kind, it.get("ref"), (b[0], b[1], b[2] - b[0], b[3] - b[1]), col,
                            it.find("orientation"), state_of(it, el) if el and el[0] == "img" else None))
        vert = rot != "ROT0"
        sc = ART_SCREEN_H / sb[3] if vert else ART_SCREEN_W / sb[2]
        cap = ART_MAX_W / max(vb[2], vb[3])                 # height too: Orientation Horz turns it into the line width
        if sc > cap:
            gq = native[::-1] if vert else native
            sc = max(cap, (gq[0] + 2) / sb[2], (gq[1] + 2) / sb[3])  # never below the game's native size + 2
            print(f"artwork {zipname}: view {v.get('name')} shrunk to the {ART_MAX_W} px line cap (scale {sc:.3f})")
        cw, ch = (round(vb[2] * sc) + 1) & ~1, round(vb[3] * sc)
        ox = round((sb[0] - vb[0]) * sc) & 1        # shift the view so the screen starts on an even pixel
        oy = round((sb[1] - vb[1]) * sc) & 1        # and an even row (the view turned 90)
        sx = round((sb[0] - vb[0]) * sc) - ox
        sy = round((sb[1] - vb[1]) * sc) - oy
        sw, sh = round(sb[2] * sc / 2) * 2, round(sb[3] * sc / 2) * 2   # = (512 down / across) when not capped
        ch = (ch + 1) & ~1
        gw, gh = native[::-1] if vert else native        # game picture as the layout shows it
        assert cw <= 2048 and ch <= 2048 and sw >= gw and sh >= gh, v.get("name")
        KIND = {"backdrop": 0, "overlay": 1, "bezel": 2, "cpanel": 3, "marquee": 3, "art": 2, "side": 0}   # OSD toggle per layer
        first, nimg = len(layers), len(images)
        qimg = 1                # this view: smallest q / 256 keeping every PNG within the resampler's 15x downscale
        for op, kind, ename, b, col, o, state in seq:
            if ename not in elems:
                continue
            el = elems[ename]
            if el[0] == "img":    # images visible in this state (no state attribute = every state)
                st = el[2] if state is None else state
                pick = [i for i in el[1] if i.get("state", st) == st]
                if not pick:          # a lamp: no image in its default state (outputs are not driven yet)
                    print(f"artwork {zipname}: element {ename} has no image for state {st}, skipped")
                    continue
                el = ("img", pick[0].get("file"), pick[0].get("alphafile"))
            rot180 = o is not None and o.get("rotate", "0") == "180"      # MAME: rotate 180 = flipx + flipy
            flipx = (o is not None and o.get("flipx") == "yes") != rot180
            flipy = (o is not None and o.get("flipy") == "yes") != rot180
            if o is not None and o.get("rotate", "0") not in ("0", "180"):
                print(f"artwork {zipname}: {ename} rotate {o.get('rotate')} not supported, drawn unrotated")

            def place(x0, y0, x1, y1):
                x = round((x0 - vb[0]) * sc); y = round((y0 - vb[1]) * sc)
                return x - ox, y - oy, round((x1 - vb[0]) * sc) - x, round((y1 - vb[1]) * sc) - y

            k = KIND[kind] << 2
            if el[0] == "rects":      # one solid-colour layer per rect, item colour x rect colour
                for rx0, ry0, rx1, ry1, rc in el[1]:
                    x, y, w, h = place(b[0] + rx0 * b[2], b[1] + ry0 * b[3], b[0] + rx1 * b[2], b[1] + ry1 * b[3])
                    if w <= 0 or h <= 0:
                        continue
                    r, gr, bl, a = (round(255 * rc[i] * col[i]) for i in range(4))
                    side = kind != "bezel" and (x + w <= sx or x >= sx + sw)
                    layers.append((op, r, 64 | ((k & ~12) if side and KIND[kind] == 2 else k) | (32 if side else 0), a, x, y, w, h, gr | bl << 8, 0))
                continue
            if col[:3] != [1.0] * 3:
                print(f"artwork {zipname}: {ename} colour tint not supported, drawn untinted")
            _, f, af = el
            x, y, w, h = place(b[0], b[1], b[0] + b[2], b[1] + b[3])
            ca = round(255 * col[3])
            assert w <= 2048, f
            for name in [n for n in (af, f) if n]:
                pw, ph = png_size(name)
                assert pw <= 15 * w and ph <= 15 * h, f"{name}: downscale factor over 15"
                qimg = max(qimg, -(-pw * 256 // (15 * max(1, w - 1))), -(-ph * 256 // (15 * max(1, h - 1))))   # view L0 high byte (1 px margin: RTL rounding)
            # side art beside the screen and taller than it: with bezels off it is scaled to the screen's height
            # (flag bit 4, alternate x / width; y / height = the screen's), so the game can fill the display
            alt, x2, w2 = 0, 0, 0
            side = kind != "bezel" and (x + w <= sx or x >= sx + sw)     # side art: OSD Side Art toggle (flag bit 5)
            if side:   # side art never follows the Bezel toggle (bezel off = side art at the screen's height)
                k = ((k & ~12) if KIND[kind] == 2 else k) | 32
            if side and h > sh:
                w2 = max(1, round(w * sh / h))
                x2 = x + w - w2 if x + w <= sx else x
                alt = 16
                for name in [n for n in (af, f) if n]:
                    pw, ph = png_size(name)
                    assert pw <= 15 * w2 and ph <= 15 * sh, f"{name}: downscale factor over 15 (bezel off)"
                    qimg = max(qimg, -(-pw * 256 // (15 * max(1, w2 - 1))), -(-ph * 256 // (15 * max(1, sh - 1))))
            fl = (1 if flipx else 0) | (128 if flipy else 0)     # the mask is flipped with its image
            if af:
                layers.append((OP_MASK, img_id(af), fl | k | alt, ca, x, y, w, h, x2, w2))
            layers.append((op, img_id(f), fl | (2 if af else 0) | k | alt, 255 if af else ca, x, y, w, h, x2, w2))
        blob = sum(4 + z.getinfo(n).file_size for n in images)
        if len(views) >= 15 or len(layers) > 112 or len(images) > 32 or blob > ART_BLOB_MAX:   # full: drop, try the next
            print(f"artwork {zipname}: view {v.get('name')} dropped, table full "
                  f"(views {len(views) + 1}/15, layers {len(layers)}/112, images {len(images)}/32, "
                  f"PNG bytes {blob}/{ART_BLOB_MAX})")
            del layers[first:], images[nimg:]
            continue
        # L0 high byte = qimg - 1 (artwork.sv floor for the HDMI fit; L0 itself is 7 bits)
        views.append((v.get("name"), (cw, ch, sx, sy, sw, sh, first | (min(qimg, 256) - 1) << 8, len(layers) - first)))
    t = bytearray(2048)
    struct.pack_into("<2sHHHHB", t, 0, b"AW", len(views), len(images), *native, ART_ROT[rot])
    for i, (_, rec) in enumerate(views):
        struct.pack_into("<8H", t, 16 + 16 * i, *rec)
    for i, (op, img, fl, ca, x, y, w, h, x2, w2) in enumerate(layers):
        struct.pack_into("<BBBBhhHHHH" if fl & 64 else "<BBBBhhHHhH", t, 256 + 16 * i, op, img, fl, ca, x, y, w, h, x2, w2)
    return bytes(t), images, [n for n, _ in views]


def art_xml(zipname, rot, port_defaults=None):
    table, images, views = art_table(zipname, rot, port_defaults)
    names = ", ".join(f"View {i + 1} = {n.replace('_', ' ')}" for i, n in enumerate(views))
    rows = "\n".join("            " + " ".join(f"{b:02X}" for b in table[i:i + 32]) for i in range(0, 2048, 32))
    parts = "\n".join(f'        <part>41 57 49 {i:02X}</part>\n        <part name="{n}"/>' for i, n in enumerate(images))
    return f"""
    <!-- Index 5: MAME artwork, layout table (from default.lay) + PNGs from the artwork zip, as-is -->
    <!-- OSD Artwork: {names} -->
    <rom index="5" md5="none" zip="/mame-artwork/{zipname}.zip">
        <part>
{rows}
        </part>
{parts}
    </rom>
"""


def art_zip(g, games):
    """Artwork zip for a set: its own, else its parent's (MAME order; a parent on other hardware counts too)."""
    if (ART_DIR / f'{g["name"]}.zip').exists():
        return g["name"]
    if g["parent"] and (ART_DIR / f'{g["parent"]}.zip').exists():
        return g["parent"]
    return None


def mra(g, games, segs, build_inputs, with_art=False):
    variant = STATE_VARIANT.get(g["state"], SUPPORTED[(g["machine"], g["init"])])
    banked, rom_map = bank_layout(segs.get(0, []), g["name"], variant)
    ports = PORT_REWRITE.get(g["machine"], lambda p: p)(build_inputs(g["inputs"]))
    idle, dips, imap, fourway, buttons, tb_rev, impulse = input_config(g, ports)
    twoway = any(f.get("twoway") and not f.get("type", "").startswith("JOYSTICKRIGHT")    # Tutankham: 2-way fire stick
                 for fields in ports.values() for f in fields)
    fire2way = any(f.get("twoway") and f.get("type", "").startswith("JOYSTICKRIGHT") for fields in ports.values() for f in fields)
    flags = (F_4WAY if fourway else 0) | (F_IMPULSE if impulse else 0) | (F_WIDE if g["init"] in WIDE_INITS or g["machine"] in WIDE_MACHINES else 0) | \
            (F_VERT if g["rot"] in ("ROT90", "ROT270") else 0) | \
            (F_ROT90 if g["rot"] == "ROT90" else 0)
    nbtn = max(buttons) if buttons else 0
    twin = any(i in TWIN_IDS for i in imap)
    if g["machine"] in BUTTONS_BY_MACHINE:
        buttons = dict(BUTTONS_BY_MACHINE[g["machine"]])
        nbtn = max(buttons)
    elif twin:                                         # Btn 3-6 carry the right-hand stick
        buttons.update({3: "R Right", 4: "R Left", 5: "R Down", 6: "R Up"})
        nbtn = 6
    names = ",".join([buttons.get(i, "Not Used") for i in range(1, 5)] + ["Coin", "Start 1P", "Start 2P", "Pause"] +
                     [buttons.get(i, "Not Used") for i in (5, 6)] +
                     ["Rack Test" if RACK_HOLD in imap or RACK_TOGGLE in imap else "Not Used"])
    parent = g["parent"] or g["name"]
    zipname = f'{g["name"]}.zip' + (f'|{g["parent"]}.zip' if g["parent"] else "")
    rotation = {"ROT0": "horizontal", "ROT270": "vertical (ccw)", "ROT90": "vertical (cw)"}[g["rot"]]
    bootleg = "yes" if "bootleg" in g["manuf"].lower() or "hack" in g["desc"].lower() else "no"
    top = games.get(parent, g)                         # parent may live in another driver (suprglob: epos)
    series, category = SERIES_BY_PARENT.get(parent, (title_case(clean_title(top["desc"])), "Maze"))
    region = next((r for w, r in REGION_WORDS if w in g["desc"]), "World")

    def part_lines(isegs):
        lines, pos = [], 0
        for s in isegs:
            if s["addr"] > pos:
                lines.append(f'        <part repeat="0x{s["addr"] - pos:X}">00</part>')
            if s.get("fill") is not None:
                lines.append(f'        <part repeat="0x{s["len"]:X}">{s["fill"]:02X}</part>')
            elif whole_file(s, isegs):
                lines.append(f'        <part crc="{s["crc"]}" name="{s["name"]}"/>')
            else:
                lines.append(f'        <part crc="{s["crc"]}" name="{s["name"]}" offset="0x{s["src"]:X}" length="0x{s["len"]:X}"/>')
            pos = s["addr"] + s["len"]
        return "\n".join(lines)

    sdram = ""
    if 2 in segs:
        sdram = f"""
    <!-- Index 2: SDRAM (large banked ROM regions) -->
    <rom index="2" md5="none" zip="{zipname}">
{part_lines(segs[2])}
    </rom>
"""

    dip_lines = "\n".join(f'        <dip name="{n}" bits="{b}" ids="{i}"' + (f' values="{v}"' if v else "") + "/>"
                          for n, b, i, v in dips)
    rom_dec, _ = DECODE.get(g["init"], (0, 0))
    flags2 = 0
    dip_ports = input_config.dip_ports
    dipsel = [dip_ports.index(p) if p in dip_ports else 0x80 for p in range(len(PORTS))]
    cfg = [variant, flags, rom_dec, flags2] + idle + dipsel + imap + rom_map
    cfg_rows = "\n".join("            " + " ".join(f"{b:02X}" for b in cfg[i:i + 16]) for i in range(0, len(cfg), 16))
    return f"""<misterromdescription>
    <name>{display_name(g)}</name>
    <region>{region}</region>
    <homebrew>no</homebrew>
    <bootleg>{bootleg}</bootleg>
    <version></version>
    <alternative></alternative>
    <platform></platform>
    <series>{series}</series>
    <year>{g["year"]}</year>
    <manufacturer>{g["manuf"]}</manufacturer>
    <category>{category}</category>

    <setname>{g["name"]}</setname>
    <parent>{parent}</parent>
    <mameversion>{MAME_VERSION}</mameversion>
    <rbf>{RBF}</rbf>
    <about></about>

    <resolution>15kHz</resolution>
    <rotation>{rotation}</rotation>
    <flip>yes</flip>

    <players>2 (alternating)</players>
    <joystick>{"2-way" if twoway else "4-way" if fourway else "8-way"}</joystick>
    <special_controls>{"trackball" if any(24 <= i < 32 for i in imap) else ("twin stick (2-way fire stick)" if fire2way else "twin stick") if twin else ""}</special_controls>
    <num_buttons>{nbtn}</num_buttons>
    <buttons names="{names}" default="A,B,X,Y,Select,Start,R,L"/>

    <switches default="{",".join(f"{idle[p]:02X}" for p in dip_ports)}">
{dip_lines}
    </switches>

    <!-- Index 0: 8K ROM banks (rtl/konami82_board.sv), PROMs at their window address in {BOARD_FILE[variant]} -->
    <rom index="0" md5="none" zip="{zipname}">
{part_lines(banked)}
    </rom>
{sdram}
    <!-- Index 1: board variant, flags, input map, ROM bank map (see Arcade-Konami82.sv) -->
    <rom index="1">
        <part>
{cfg_rows}
        </part>
    </rom>
{hiscore_xml(g)}{art_xml(art_zip(g, games), g["rot"], {t: port_default(f) for t, f in ports.items()}) if with_art else ""}
    <remark>{remark(g)}</remark>
    <mratimestamp>20261015000000</mratimestamp>
</misterromdescription>
"""


def title_case(text):
    """Capitalise every word, small words included; acronyms (US, II, PCB) stay as written."""
    out = []
    for word in re.split(r"(\s+|[()/,-])", text):
        if word and word[0].isalpha():
            word = word[0].upper() + word[1:]
        out.append(word)
    return "".join(out)


def clean_title(desc):
    """Parent title: the description without its trailing parenthesised qualifiers."""
    return re.sub(r"(\s*\([^()]*\))+$", "", desc).strip()


def display_name(g):
    return title_case(clean_title(g["desc"]) if g["parent"] is None else g["desc"])


def remark(g):
    """'Title (Maker)', without repeating a maker the title already names."""
    m = re.fullmatch(r'bootleg \((.+)\)', g["manuf"])
    maker = f"{m.group(1)} bootleg" if m else g["manuf"]
    desc = title_case(g["desc"])
    return desc if maker.lower() in g["desc"].lower() else f"{desc} ({title_case(maker)})"


def safe(name):
    name = re.sub(r'\?', "", name)                     # "bootleg?" -> "bootleg"
    return re.sub(r'\s*/\s*', " - ", re.sub(r'[\\:*"<>|]', "-", name))


def out_path(root, g, games):
    if g["parent"] is None:
        return root / f"{safe(display_name(g))}.mra"
    parent_title = display_name(games[g["parent"]]) if g["parent"] in games else title_case(clean_title(g["desc"]))
    return root / "_alternatives" / f"_{safe(parent_title)}" / f"{safe(display_name(g))}.mra"


KONAMIPT = Path(__file__).resolve().parent.parent / "Useful Information/mame/konamipt.h"


def load_source(files):
    """Driver sources with #includes dropped and konamipt.h macros expanded by the C preprocessor."""
    body = "\n".join(l for f in files for l in Path(f).read_text().splitlines() if not l.lstrip().startswith("#include"))
    defs = "\n".join(l for l in KONAMIPT.read_text().splitlines() if not l.lstrip().startswith("#include"))
    out = subprocess.run(["cpp", "-P", "-w", "-x", "c++", "-std=c++17"], input=defs + "\n" + body,
                         capture_output=True, text=True, check=True).stdout
    return out


def main():
    src = load_source(sys.argv[1].split(","))
    out_dir = Path(sys.argv[2])
    games = parse_games(src)
    build_inputs = parse_inputs(src)
    names = sys.argv[3:] or [n for n, g in games.items()
                             if (g["machine"], g["init"]) in SUPPORTED and (g["working"] or n in WORKING_HERE)]
    for name in names:
        g = games[name]
        if (g["machine"], g["init"]) not in SUPPORTED:
            raise SystemExit(f'{name}: board {g["machine"]} / {g["init"]} not implemented')
        segs = place(parse_roms(src, name), name, g["machine"])
        for root, with_art in [(out_dir, False)] + ([(out_dir / "_artwork", True)] if art_zip(g, games) else []):
            path = out_path(root, g, games)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(mra(g, games, segs, build_inputs, with_art))
            print(f'{name:12s} {path.relative_to(out_dir)}')


if __name__ == "__main__":
    main()
