#!/usr/bin/env python3
"""
ttygif.py - record a terminal program to an animated GIF.

Self-contained: uses only the Python standard library + Pillow (PIL).
No external binaries, no network.

  1. Runs the given command in a pseudo-terminal of a fixed size (cols x rows).
  2. Captures its output (with timestamps) until it exits or --duration elapses.
  3. Replays the byte stream through a small built-in VT/ANSI terminal emulator,
     sampling the screen at --fps and rendering each frame with a monospace font.
  4. Writes an animated GIF.

Usage:
  ttygif.py --out demo.gif --cols 80 --rows 15 --duration 2 -- crystal run foo.cr
"""

import argparse
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time
import unicodedata

from PIL import Image, ImageDraw, ImageFont

# --------------------------------------------------------------------------- #
# Capture: run command in a PTY, return list of (timestamp, bytes)            #
# --------------------------------------------------------------------------- #


import re

# Terminal capability queries a TUI may send and *block* waiting on. We answer
# them like a real xterm would, so the program proceeds to actually draw.
_RE_OSC_COLOR = re.compile(rb"\x1b\]1([012]);\?(?:\x07|\x1b\\)")
_RE_OSC_PALETTE = re.compile(rb"\x1b\]4;(\d+);\?(?:\x07|\x1b\\)")
_RE_DECRQSS = re.compile(rb"\x1bP\$q(.*?)\x1b\\")


def _osc_color_reply(n, rgb):
    r, g, b = rgb
    return ("\x1b]1%s;rgb:%02x%02x/%02x%02x/%02x%02x\x07"
            % (n, r, r, g, g, b, b)).encode()


def _answer_queries(buf, cap_term):
    """Consume known queries from buf; respond like a real terminal.

    cap_term tracks the cursor so a cursor-position report (which TUIs use to
    measure character cell width) gets the right column back.
    """
    out = []
    i = 0
    n = len(buf)
    flushed = 0  # bytes already fed into cap_term

    def feed_to(idx):
        nonlocal flushed
        if idx > flushed:
            cap_term.feed(buf[flushed:idx],
                          __import__("codecs").getincrementaldecoder("utf-8")("replace"))
            flushed = idx

    while i < n:
        if buf.startswith(b"\x1b[6n", i):       # cursor position report
            feed_to(i)
            out.append(("\x1b[%d;%dR" % (cap_term.cy + 1, cap_term.cx + 1)).encode())
            i += 4; flushed = i; continue
        if buf.startswith(b"\x1b[5n", i):       # device status
            feed_to(i); out.append(b"\x1b[0n"); i += 4; flushed = i; continue
        matched = False
        for pat, reply in ((b"\x1b[>c", b"\x1b[>0;276;0c"),
                           (b"\x1b[>0c", b"\x1b[>0;276;0c"),
                           (b"\x1b[c", b"\x1b[?64;1;2;6;9;15;18;21;22c"),
                           (b"\x1b[0c", b"\x1b[?64;1;2;6;9;15;18;21;22c")):
            if buf.startswith(pat, i):           # device attributes
                feed_to(i); out.append(reply); i += len(pat); flushed = i
                matched = True; break
        if matched:
            continue
        mm = _RE_OSC_COLOR.match(buf, i)         # OSC fg/bg/cursor color query
        if mm:
            feed_to(i)
            which = mm.group(1).decode()
            rgb = {"0": DEFAULT_FG, "1": DEFAULT_BG, "2": DEFAULT_FG}[which]
            out.append(_osc_color_reply(which, rgb)); i = mm.end(); flushed = i; continue
        mm = _RE_OSC_PALETTE.match(buf, i)       # OSC palette query
        if mm:
            feed_to(i)
            idx = int(mm.group(1))
            r, g, b = XTERM256[max(0, min(255, idx))]
            out.append(("\x1b]4;%d;rgb:%02x%02x/%02x%02x/%02x%02x\x07"
                        % (idx, r, r, g, g, b, b)).encode())
            i = mm.end(); flushed = i; continue
        mm = _RE_DECRQSS.match(buf, i)           # DECRQSS status request
        if mm:
            feed_to(i)
            req = mm.group(1)
            body = b"0m" if req == b"m" else req
            out.append(b"\x1bP1$r" + body + b"\x1b\\"); i = mm.end(); flushed = i; continue
        i += 1

    feed_to(n)
    return out


def capture(argv, cols, rows, duration, env_extra=None):
    pid, fd = pty.fork()
    if pid == 0:  # child
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = str(cols)
        env["LINES"] = str(rows)
        env["COLORTERM"] = "truecolor"
        if env_extra:
            env.update(env_extra)
        try:
            os.execvpe(argv[0], argv, env)
        except Exception as e:  # pragma: no cover
            sys.stderr.write("exec failed: %s\n" % e)
            os._exit(127)

    # parent: set window size on the pty
    winsize = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)

    cap_term = Terminal(cols, rows)  # cursor tracking for CPR replies
    events = []
    start = time.time()
    deadline = start + duration
    while True:
        timeout = deadline - time.time()
        if timeout <= 0:
            break
        try:
            r, _, _ = select.select([fd], [], [], timeout)
        except select.error as e:
            if e.args[0] == errno.EINTR:
                continue
            raise
        if fd in r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            events.append((time.time() - start, data))
            for rep in _answer_queries(data, cap_term):
                try:
                    os.write(fd, rep)
                except OSError:
                    pass

    # tear the child down
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    time.sleep(0.05)
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass
    return events


# --------------------------------------------------------------------------- #
# xterm 256-color palette                                                      #
# --------------------------------------------------------------------------- #


def build_xterm256():
    pal = []
    # 0..15 standard
    base = [
        (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
        (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
        (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
        (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
    ]
    pal.extend(base)
    # 16..231 6x6x6 cube
    levels = [0, 95, 135, 175, 215, 255]
    for r in range(6):
        for g in range(6):
            for b in range(6):
                pal.append((levels[r], levels[g], levels[b]))
    # 232..255 grayscale
    for i in range(24):
        v = 8 + i * 10
        pal.append((v, v, v))
    return pal


XTERM256 = build_xterm256()

DEFAULT_FG = (0xCC, 0xCC, 0xCC)
DEFAULT_BG = (0x0C, 0x0C, 0x0C)

# DEC special graphics (line drawing) mapping for ESC ( 0
DEC_GRAPHICS = {
    "j": "┘", "k": "┐", "l": "┌", "m": "└", "n": "┼",
    "q": "─", "t": "├", "u": "┤", "v": "┴", "w": "┬",
    "x": "│", "`": "◆", "a": "▒", "f": "°", "g": "±",
    "~": "·", "o": "⎺", "p": "⎻", "r": "⎼", "s": "⎽",
    "0": "█",
}


def char_width(ch):
    if ch == "":
        return 0
    o = ord(ch)
    if o == 0:
        return 0
    # Box/block elements, braille, and the legacy-computing sextants/octants are
    # all single-width cells (terminals treat them as width 1). Pin them so the
    # incomplete Unicode tables in older Pythons don't mis-flag them as wide.
    if (0x2500 <= o <= 0x259F or 0x2800 <= o <= 0x28FF
            or 0x1FB00 <= o <= 0x1FBFF or 0x1CC00 <= o <= 0x1CEBF):
        return 1
    if unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


class Cell:
    __slots__ = ("ch", "fg", "bg", "bold", "underline", "inverse", "italic")

    def __init__(self):
        self.ch = " "
        self.fg = None
        self.bg = None
        self.bold = False
        self.underline = False
        self.inverse = False
        self.italic = False

    def copy(self):
        c = Cell()
        c.ch = self.ch
        c.fg = self.fg
        c.bg = self.bg
        c.bold = self.bold
        c.underline = self.underline
        c.inverse = self.inverse
        c.italic = self.italic
        return c


class Terminal:
    """A deliberately small VT100/xterm emulator: enough for full-screen TUIs."""

    def __init__(self, cols, rows):
        self.cols = cols
        self.rows = rows
        self.reset()

    def reset(self):
        self.grid = [[Cell() for _ in range(self.cols)] for _ in range(self.rows)]
        self.cx = 0
        self.cy = 0
        self.fg = None
        self.bg = None
        self.bold = False
        self.underline = False
        self.inverse = False
        self.italic = False
        self.cursor_visible = True
        self.g0_graphics = False
        self.saved = None
        self._pending = ""  # incomplete escape sequence carried across feeds

    # -- helpers -----------------------------------------------------------
    def _new_cell(self):
        c = Cell()
        c.fg = self.fg
        c.bg = self.bg
        c.bold = self.bold
        c.underline = self.underline
        c.inverse = self.inverse
        c.italic = self.italic
        return c

    def _clamp(self):
        self.cx = max(0, min(self.cx, self.cols - 1))
        self.cy = max(0, min(self.cy, self.rows - 1))

    def _scroll_up(self):
        self.grid.pop(0)
        self.grid.append([Cell() for _ in range(self.cols)])

    # -- printable ---------------------------------------------------------
    def put_char(self, ch):
        if self.g0_graphics and ch in DEC_GRAPHICS:
            ch = DEC_GRAPHICS[ch]
        w = char_width(ch)
        if w == 0:
            # combining: attach to previous cell if possible
            if self.cx > 0:
                prev = self.grid[self.cy][self.cx - 1]
                prev.ch = prev.ch + ch
            return
        if self.cx >= self.cols:
            self.cx = 0
            self.cy += 1
            if self.cy >= self.rows:
                self._scroll_up()
                self.cy = self.rows - 1
        cell = self._new_cell()
        cell.ch = ch
        self.grid[self.cy][self.cx] = cell
        if w == 2 and self.cx + 1 < self.cols:
            filler = self._new_cell()
            filler.ch = ""  # spacer for wide char
            self.grid[self.cy][self.cx + 1] = filler
        self.cx += w

    # -- SGR ---------------------------------------------------------------
    def sgr(self, params):
        if not params:
            params = [0]
        i = 0
        while i < len(params):
            p = params[i]
            if p == 0:
                self.fg = None
                self.bg = None
                self.bold = False
                self.underline = False
                self.inverse = False
                self.italic = False
            elif p == 1:
                self.bold = True
            elif p == 22:
                self.bold = False
            elif p == 3:
                self.italic = True
            elif p == 23:
                self.italic = False
            elif p == 4:
                self.underline = True
            elif p == 24:
                self.underline = False
            elif p == 7:
                self.inverse = True
            elif p == 27:
                self.inverse = False
            elif 30 <= p <= 37:
                self.fg = XTERM256[p - 30]
            elif p == 39:
                self.fg = None
            elif 40 <= p <= 47:
                self.bg = XTERM256[p - 40]
            elif p == 49:
                self.bg = None
            elif 90 <= p <= 97:
                self.fg = XTERM256[8 + p - 90]
            elif 100 <= p <= 107:
                self.bg = XTERM256[8 + p - 100]
            elif p == 38 or p == 48:
                target_fg = p == 38
                if i + 1 < len(params) and params[i + 1] == 5:
                    n = params[i + 2] if i + 2 < len(params) else 0
                    col = XTERM256[max(0, min(255, n))]
                    i += 2
                elif i + 1 < len(params) and params[i + 1] == 2:
                    r = params[i + 2] if i + 2 < len(params) else 0
                    g = params[i + 3] if i + 3 < len(params) else 0
                    b = params[i + 4] if i + 4 < len(params) else 0
                    col = (r, g, b)
                    i += 4
                else:
                    col = None
                if target_fg:
                    self.fg = col
                else:
                    self.bg = col
            i += 1

    # -- erase -------------------------------------------------------------
    def erase_line(self, mode):
        row = self.grid[self.cy]
        if mode == 0:
            rng = range(self.cx, self.cols)
        elif mode == 1:
            rng = range(0, self.cx + 1)
        else:
            rng = range(0, self.cols)
        for x in rng:
            row[x] = self._new_cell()

    def erase_display(self, mode):
        if mode == 0:
            self.erase_line(0)
            for y in range(self.cy + 1, self.rows):
                self.grid[y] = [self._new_cell() for _ in range(self.cols)]
        elif mode == 1:
            self.erase_line(1)
            for y in range(0, self.cy):
                self.grid[y] = [self._new_cell() for _ in range(self.cols)]
        else:
            for y in range(self.rows):
                self.grid[y] = [self._new_cell() for _ in range(self.cols)]

    # -- CSI dispatch ------------------------------------------------------
    def csi(self, params, private, final):
        def arg(n, default=1):
            if n < len(params) and params[n] is not None:
                return params[n]
            return default

        if final == "H" or final == "f":
            self.cy = arg(0, 1) - 1
            self.cx = arg(1, 1) - 1
            self._clamp()
        elif final == "A":
            self.cy -= arg(0); self._clamp()
        elif final == "B":
            self.cy += arg(0); self._clamp()
        elif final == "C":
            self.cx += arg(0); self._clamp()
        elif final == "D":
            self.cx -= arg(0); self._clamp()
        elif final == "G":
            self.cx = arg(0, 1) - 1; self._clamp()
        elif final == "d":
            self.cy = arg(0, 1) - 1; self._clamp()
        elif final == "J":
            self.erase_display(arg(0, 0))
        elif final == "K":
            self.erase_line(arg(0, 0))
        elif final == "m":
            self.sgr([p if p is not None else 0 for p in params] or [0])
        elif final == "h" and private:
            for p in params:
                if p == 25:
                    self.cursor_visible = True
        elif final == "l" and private:
            for p in params:
                if p == 25:
                    self.cursor_visible = False
        elif final == "P":  # delete chars
            n = arg(0); row = self.grid[self.cy]
            del row[self.cx:self.cx + n]
            while len(row) < self.cols:
                row.append(self._new_cell())
        elif final == "@":  # insert chars
            n = arg(0); row = self.grid[self.cy]
            for _ in range(n):
                row.insert(self.cx, self._new_cell())
            self.grid[self.cy] = row[:self.cols]
        # other CSI ignored

    # -- byte feed ---------------------------------------------------------
    def feed(self, data, decoder):
        text = self._pending + decoder.decode(data)
        self._pending = ""
        i = 0
        n = len(text)
        while i < n:
            ch = text[i]
            o = ord(ch)
            if o == 0x1b:  # ESC
                r = self._esc(text, i + 1)
                if r < 0:  # sequence not complete yet; carry to next feed
                    self._pending = text[i:]
                    return
                i = r
                continue
            if o == 0x0d:
                self.cx = 0
            elif o == 0x0a or o == 0x0b or o == 0x0c:
                self.cy += 1
                if self.cy >= self.rows:
                    self._scroll_up()
                    self.cy = self.rows - 1
            elif o == 0x08:
                self.cx = max(0, self.cx - 1)
            elif o == 0x09:
                self.cx = min(self.cols - 1, (self.cx // 8 + 1) * 8)
            elif o == 0x0e:  # SO -> G1 (treat as graphics off here)
                self.g0_graphics = True
            elif o == 0x0f:  # SI -> G0
                self.g0_graphics = False
            elif o < 0x20:
                pass
            else:
                self.put_char(ch)
            i += 1

    def _esc(self, text, i):
        # returns next index, or -1 if the sequence is incomplete
        n = len(text)
        if i >= n:
            return -1
        c = text[i]
        if c == "[":
            return self._csi(text, i + 1)
        if c == "]":  # OSC: skip to BEL or ST
            j = i + 1
            while j < n:
                if text[j] == "\x07":
                    return j + 1
                if text[j] == "\x1b":
                    if j + 1 < n:
                        return j + 2 if text[j + 1] == "\\" else j + 1
                    return -1  # ESC at end: could be start of ST
                j += 1
            return -1  # no terminator yet
        if c in "P X ^ _".split():  # DCS/SOS/PM/APC: string until ST
            j = i + 1
            while j < n:
                if text[j] == "\x1b":
                    if j + 1 < n:
                        return j + 2 if text[j + 1] == "\\" else j + 1
                    return -1
                j += 1
            return -1
        if c in "()*+":  # charset designation
            if i + 1 < n:
                if c == "(":
                    self.g0_graphics = text[i + 1] == "0"
                return i + 2
            return -1
        if c == "7":
            self.saved = (self.cx, self.cy, self.fg, self.bg, self.bold,
                          self.underline, self.inverse, self.italic)
            return i + 1
        if c == "8":
            if self.saved:
                (self.cx, self.cy, self.fg, self.bg, self.bold,
                 self.underline, self.inverse, self.italic) = self.saved
            return i + 1
        if c == "M":  # reverse index
            self.cy -= 1
            if self.cy < 0:
                self.cy = 0
            return i + 1
        if c in "=>":
            return i + 1
        return i + 1

    def _csi(self, text, i):
        n = len(text)
        private = False
        buf = []
        while i < n:
            c = text[i]
            o = ord(c)
            if c == "?" and not buf:
                private = True
                i += 1
                continue
            if 0x30 <= o <= 0x3f:  # params / intermediate
                buf.append(c)
                i += 1
                continue
            if 0x20 <= o <= 0x2f:  # intermediate bytes
                i += 1
                continue
            if 0x40 <= o <= 0x7e:  # final byte
                params = self._parse_params("".join(buf))
                self.csi(params, private, c)
                return i + 1
            # unexpected byte: abort this sequence here
            return i + 1
        return -1  # ran out of input before final byte

    @staticmethod
    def _parse_params(s):
        if s == "":
            return []
        out = []
        for part in s.split(";"):
            if part == "":
                out.append(None)
            else:
                try:
                    out.append(int(part))
                except ValueError:
                    out.append(None)
        return out


# --------------------------------------------------------------------------- #
# Rendering                                                                    #
# --------------------------------------------------------------------------- #


def load_fonts(size):
    sets = {
        "r": ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
              "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf"],
        "b": ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
              "/usr/share/fonts/truetype/noto/NotoSansMono-Bold.ttf"],
        "i": ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Oblique.ttf"],
        "bi": ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono-BoldOblique.ttf"],
    }

    def first(paths):
        for p in paths:
            if os.path.exists(p):
                return p
        return None

    reg = first(sets["r"])
    fonts = {"r": ImageFont.truetype(reg, size)}
    for key in ("b", "i", "bi"):
        path = first(sets[key]) or reg
        fonts[key] = ImageFont.truetype(path, size)
    return fonts


def pick_font(fonts, bold, italic):
    if bold and italic:
        return fonts["bi"]
    if bold:
        return fonts["b"]
    if italic:
        return fonts["i"]
    return fonts["r"]


def cell_metrics(font):
    # width of a representative glyph; height from font metrics
    bbox = font.getbbox("M")
    w = font.getlength("M")
    ascent, descent = font.getmetrics()
    return int(round(w)), ascent + descent, ascent


# --------------------------------------------------------------------------- #
# Sub-cell glyphs (half/quadrant/sextant/octant/braille) drawn geometrically,  #
# so they render pixel-accurately regardless of font coverage. Mirrors the     #
# bit/codepoint layout emitted by Crysterm's Widget::Image::Glyph.               #
# --------------------------------------------------------------------------- #

_BLOCK_MAP = {
    0x2580: (1, 2, [(0, 0)]), 0x2584: (1, 2, [(0, 1)]),         # upper / lower half
    0x258C: (2, 1, [(0, 0)]), 0x2590: (2, 1, [(1, 0)]),         # left / right half
    0x2588: (1, 1, [(0, 0)]),                                   # full block
    0x2596: (2, 2, [(0, 1)]), 0x2597: (2, 2, [(1, 1)]),
    0x2598: (2, 2, [(0, 0)]), 0x259D: (2, 2, [(1, 0)]),
    0x259A: (2, 2, [(0, 0), (1, 1)]), 0x259E: (2, 2, [(1, 0), (0, 1)]),
    0x2599: (2, 2, [(0, 0), (0, 1), (1, 1)]),
    0x259B: (2, 2, [(0, 0), (1, 0), (0, 1)]),
    0x259C: (2, 2, [(0, 0), (1, 0), (1, 1)]),
    0x259F: (2, 2, [(1, 0), (0, 1), (1, 1)]),
}

_BRAILLE_BIT_POS = {
    0x01: (0, 0), 0x02: (0, 1), 0x04: (0, 2), 0x40: (0, 3),
    0x08: (1, 0), 0x10: (1, 1), 0x20: (1, 2), 0x80: (1, 3),
}


def _cells_from_mask(mask, sx, sy):
    return [(dx, dy) for dy in range(sy) for dx in range(sx)
            if mask & (1 << (dy * sx + dx))]


def _build_skip_map(base, n, skip):
    m2cp = {}
    idx = 0
    for m in range(n):
        if m in skip:
            continue
        m2cp[base + idx] = m
        idx += 1
    return m2cp


_SEXTANT_CP2MASK = _build_skip_map(0x1FB00, 64, {0, 21, 42, 63})
_OCTANT_CP2MASK = _build_skip_map(0x1CD00, 256, {0, 255, 15, 240, 85, 170})


def geometric(cp):
    if 0x2800 <= cp <= 0x28FF:
        return ("braille", cp - 0x2800)
    b = _BLOCK_MAP.get(cp)
    if b:
        return ("blocks", b[0], b[1], b[2])
    if 0x1FB00 <= cp <= 0x1FB3B:
        m = _SEXTANT_CP2MASK.get(cp)
        if m is not None:
            return ("blocks", 2, 3, _cells_from_mask(m, 2, 3))
    m = _OCTANT_CP2MASK.get(cp)
    if m is not None:
        return ("blocks", 2, 4, _cells_from_mask(m, 2, 4))
    return None


def render_grid(term, fonts, cw, ch_h, ascent, scale=1):
    W = term.cols * cw
    H = term.rows * ch_h
    img = Image.new("RGB", (W, H), DEFAULT_BG)
    draw = ImageDraw.Draw(img)
    for y in range(term.rows):
        row = term.grid[y]
        py = y * ch_h
        x = 0
        while x < term.cols:
            cell = row[x]
            if cell.ch == "":  # spacer of a wide glyph
                x += 1
                continue
            fg = cell.fg if cell.fg is not None else DEFAULT_FG
            bg = cell.bg if cell.bg is not None else DEFAULT_BG
            if cell.inverse:
                fg, bg = bg, fg
            w = char_width(cell.ch[0]) if cell.ch else 1
            w = max(1, w)
            px = x * cw

            # Sub-cell glyph families: draw geometrically (font-independent).
            geo = geometric(ord(cell.ch[0])) if cell.ch else None
            if geo:
                draw.rectangle([px, py, px + cw - 1, py + ch_h - 1], fill=bg)
                if geo[0] == "braille":
                    mask = geo[1]
                    for bit, (dx, dy) in _BRAILLE_BIT_POS.items():
                        if mask & bit:
                            x0 = px + dx * cw / 2.0
                            y0 = py + dy * ch_h / 4.0
                            ddx = cw / 2.0
                            ddy = ch_h / 4.0
                            ix = ddx * 0.16
                            iy = ddy * 0.16
                            draw.ellipse([x0 + ix, y0 + iy, x0 + ddx - ix - 1, y0 + ddy - iy - 1],
                                         fill=fg)
                else:
                    _, cols, rows, cells = geo
                    for (dx, dy) in cells:
                        x0 = px + round(dx * cw / cols)
                        x1 = px + round((dx + 1) * cw / cols)
                        y0 = py + round(dy * ch_h / rows)
                        y1 = py + round((dy + 1) * ch_h / rows)
                        draw.rectangle([x0, y0, x1 - 1, y1 - 1], fill=fg)
                x += w
                continue

            # background
            if bg != DEFAULT_BG:
                draw.rectangle([px, py, px + w * cw - 1, py + ch_h - 1], fill=bg)
            # glyph
            if cell.ch.strip(" ") and cell.ch != " ":
                f = pick_font(fonts, cell.bold, cell.italic)
                draw.text((px, py), cell.ch, font=f, fill=fg)
                if cell.underline:
                    uy = py + ascent + 1
                    draw.line([px, uy, px + w * cw - 1, uy], fill=fg)
            x += w
    if scale != 1:
        img = img.resize((W * scale, H * scale), Image.NEAREST)
    return img


# --------------------------------------------------------------------------- #
# Main                                                                         #
# --------------------------------------------------------------------------- #


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--cols", type=int, default=80)
    ap.add_argument("--rows", type=int, default=15)
    ap.add_argument("--duration", type=float, default=2.0)
    ap.add_argument("--fps", type=float, default=12.0)
    ap.add_argument("--font-size", type=int, default=18)
    ap.add_argument("--scale", type=int, default=1)
    ap.add_argument("--settle", type=float, default=0.4,
                    help="extra seconds to hold the final frame")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    cmd = args.cmd
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        ap.error("no command given (use -- before the command)")

    sys.stderr.write("  capturing (%dx%d, %.1fs) ...\n" % (args.cols, args.rows, args.duration))
    events = capture(cmd, args.cols, args.rows, args.duration)
    if not events:
        sys.stderr.write("  WARNING: no output captured\n")

    # Replay & sample frames at fps
    term = Terminal(args.cols, args.rows)
    decoder = __import__("codecs").getincrementaldecoder("utf-8")("replace")
    fonts = load_fonts(args.font_size)
    cw, ch_h, ascent = cell_metrics(fonts["r"])

    # Still mode: if the output is a .png, replay everything and save the final
    # frame as a single image (for static demos that would otherwise flicker as
    # a 2-frame GIF).
    if args.out.lower().endswith(".png"):
        for _, data in events:
            term.feed(data, decoder)
        img = render_grid(term, fonts, cw, ch_h, ascent, args.scale)
        img.save(args.out)
        sys.stderr.write("  done (still): %s\n" % args.out)
        return

    frame_dt = 1.0 / args.fps
    frames = []
    durations = []
    ev_idx = 0
    t = 0.0
    end = args.duration
    last_event_t = events[-1][0] if events else 0.0
    end = min(end, last_event_t + 0.001) if events else end

    while t <= end + 1e-6:
        # feed all events up to time t
        while ev_idx < len(events) and events[ev_idx][0] <= t:
            term.feed(events[ev_idx][1], decoder)
            ev_idx += 1
        frames.append(render_grid(term, fonts, cw, ch_h, ascent, args.scale))
        durations.append(int(frame_dt * 1000))
        t += frame_dt

    # feed any remainder and add a settle frame
    while ev_idx < len(events):
        term.feed(events[ev_idx][1], decoder)
        ev_idx += 1
    frames.append(render_grid(term, fonts, cw, ch_h, ascent, args.scale))
    durations.append(int(args.settle * 1000))

    sys.stderr.write("  rendering %d frames -> %s\n" % (len(frames), args.out))
    # quantize for compact GIF
    pal_frames = [f.convert("P", palette=Image.ADAPTIVE, colors=256) for f in frames]
    pal_frames[0].save(
        args.out,
        save_all=True,
        append_images=pal_frames[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=2,
    )
    sys.stderr.write("  done: %s (%d frames)\n" % (args.out, len(frames)))


if __name__ == "__main__":
    main()
