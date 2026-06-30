require "../../../src/crysterm"

# Terminal identification (tid).
#
# Dumps to stdout everything Crysterm/Tput was able to determine about the
# terminal it is running in:
#
#   IDENTITY   resolved terminal name, aliases, terminfo, screen size
#   EMULATOR   which emulator program it detected (and from what)
#   GRAPHICS   derived in-band graphics capabilities (kitty / iterm / sixel)
#   FEATURES   statically-detected features (env vars + terminfo), then the
#              results of live probing (round-tripping query escape sequences
#              and reading the replies)
#
# With -v / --verbose, it also prints the *Crysterm-specific* terminal/rendering
# determinations that sit on top of Tput — the effective color depth (after the
# NO_COLOR / FORCE_COLOR / colors.depth policies), the unicode rendering mode,
# the detected cell pixel size, and the per-terminal `DrawCaps` fast-path flags
# the drawer derives once per terminal.
#
# Each line shows the setting name, its value, and a short description of *how*
# that value was determined.
#
# Run with:  crystal examples/terminal/tid/tid.cr [-v|--verbose]
module Crysterm
  include Tput::Namespace

  verbose = true # ARGV.any? { |a| a.in?("-v", "--verbose") }

  # A `Screen` is the physical device: constructing it builds the `Tput` (with
  # `probe: false`) *and*, on top of it, Crysterm's per-terminal `DrawCaps` — all
  # without entering the alt-screen or otherwise taking over the terminal. (The
  # terminfo for the current $TERM is loaded automatically, with an `xterm`
  # fallback when the environment has none.)
  screen = Screen.new
  tput = screen.tput

  # Round-trip the live query sequences (colors, palette, cursor style,
  # kitty/modifyOtherKeys, DA1/DA2, XTVERSION, …) and read the terminal's
  # replies. This populates the "live probing" section. It no-ops when not
  # attached to a real terminal (e.g. output redirected), in which case that
  # section reads "(no reply)"/"(not probed)" — that is expected.
  tput.probe!

  tput.dump STDOUT

  if verbose
    # Crysterm-specific cell-pixel detection (ioctl, with an XTWINOPS fallback).
    screen.detect_cell_geometry

    # Small aligned printer matching the layout of `Tput#dump`.
    section = ->(title : String, rows : Array({String, String, String})) {
      puts
      puts title
      nw = rows.max_of(&.[0].size)
      vw = rows.max_of(&.[1].size)
      rows.each { |name, value, note| puts "  #{name.ljust(nw)}  #{value.ljust(vw)}  #{note}" }
    }
    # Renders a raw capability byte string (e.g. smacs/el) readably.
    esc = ->(b : Bytes) { b.empty? ? "(none)" : String.new(b).inspect }

    f = tput.features

    section.call "CRYSTERM (rendering — derived on top of Tput)", [
      {"size", "#{screen.width} x #{screen.height}",
       screen.explicit_size? ? "explicit (constructor)" : "probed from terminal"},
      {"colors", screen.colors.to_s,
       "effective depth; policy #{Config.screen_color_force} / #{Config.colors_depth}, tput detected #{f.number_of_colors}"},
      {"truecolor", screen.truecolor?.to_s, "effective (colors >= 16M)"},
      {"force_unicode", screen.force_unicode?.to_s, "Crysterm option (screen.force_unicode)"},
      {"full_unicode (requested)", screen.full_unicode_requested.to_s, "Crysterm option (screen.full_unicode)"},
      {"full_unicode (effective)", screen.full_unicode?.to_s, "option AND terminal unicode (#{f.unicode?})"},
      {"hardware_cursor_styling", screen.hardware_cursor_styling?.to_s, "from Tput cursor_style (DECSCUSR / OSC 50)"},
      {"hardware_cursor_color", screen.hardware_cursor_color?.to_s, "from Tput cursor_color (OSC 12)"},
      {"cell_pixels", "#{screen.cell_pixel_width} x #{screen.cell_pixel_height}",
       screen.cell_pixel_width > 0 ? "detected (ioctl / XTWINOPS)" : "terminal reported none"},
      {"cell_aspect_ratio", CSS::Length.cell_aspect_ratio.to_s,
       CSS::Length.cell_aspect_ratio_configured? ? "pinned (css.cell_aspect_ratio)" : "derived from cell_pixels (default 2.0)"},
      {"headless", Crysterm.headless?.to_s, "no real tty / IO redirected"},
    ]

    dc = screen.draw_caps
    section.call "CRYSTERM (draw_caps — per-terminal drawer fast path)", [
      {"has_bce", dc.has_bce.to_s, "terminfo back_color_erase"},
      {"parm_right_cursor", dc.parm_right_cursor.to_s, "terminfo parm_right_cursor present"},
      {"alt_charset", dc.alt_charset.to_s, "terminfo enter_alt_charset present"},
      {"broken_acs", dc.broken_acs.to_s, "from Tput features"},
      {"term_unicode", dc.term_unicode.to_s, "from Tput features (unicode?)"},
      {"u8", dc.u8.try(&.to_s) || "(none)", "terminfo extension U8"},
      {"ncolors", dc.ncolors.to_s, "color count snapshot at construction"},
      {"acscr", "#{dc.acscr.size} mapping(s)", "ACS reverse map (glyph substitution)"},
      {"smacs", esc.call(dc.smacs), "enter-alt-charset bytes"},
      {"rmacs", esc.call(dc.rmacs), "exit-alt-charset bytes"},
      {"el", esc.call(dc.el), "erase-to-end-of-line bytes"},
      {"ansi_cursor", dc.ansi_cursor.to_s, "cursor moves are byte-for-byte ANSI (inline hot path)"},
    ]
  end
end
