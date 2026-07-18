require "../../../src/crysterm"

# tid — terminal identification.
#
# Standalone diagnostic answering: what terminal am I running in, and what can
# it do? Leads with a synthesized verdict — likely terminal, version,
# confidence — then the full evidence: environment hints, resolved terminfo,
# emulator/feature heuristics, and (on a real TTY) the terminal's own replies to
# live query sequences. The replies are authoritative; the heuristics are not.
#
# Usage:
#   crystal run examples/terminal/tid/tid.cr -- [options]
#
#   -v, --verbose    also dump Crysterm's own rendering determinations
#       --no-probe   don't round-trip query sequences (env/terminfo only)
#       --json       emit machine-readable JSON instead of the report
#   -h, --help       show this help
#
# Probing only happens on a real terminal; when output is redirected (a pipe or
# file) the live section is skipped and the verdict falls back to env/TERM
# heuristics — called out in the report.
module Crysterm
  include Tput::Namespace

  verbose = no_probe = json = false
  ARGV.each do |arg|
    case arg
    when "-v", "--verbose" then verbose = true
    when "--no-probe"      then no_probe = true
    when "--json"          then json = true
    when "-h", "--help"
      puts <<-HELP
        tid — terminal identification

        Usage: tid [options]

          -v, --verbose    also dump Crysterm's rendering determinations
              --no-probe   don't round-trip query sequences (env/terminfo only)
              --json       emit machine-readable JSON instead of the report
          -h, --help       show this help
        HELP
      exit 0
    else
      STDERR.puts "tid: unknown option #{arg.inspect} (try --help)"
      exit 2
    end
  end

  # A `Screen` is the physical device: constructing it builds the `Tput` (with
  # `probe: false`) and, on top of it, Crysterm's per-terminal `DrawCaps` —
  # without entering the alt-screen or otherwise taking over the terminal.
  # (Terminfo for $TERM loads automatically, with an `xterm` fallback.)
  screen = Screen.new
  tput = screen.tput

  # Ask the terminal about itself: round-trip live query sequences (colors,
  # palette, cursor style, kitty/modifyOtherKeys, DA1/DA2, XTVERSION, …) and
  # read the replies, turning a "best guess" into a confirmed identity. No-ops
  # when not attached to a real terminal, so the report shows only what
  # env/terminfo can prove.
  unless no_probe
    tput.probe!
    # Cell pixel geometry (ioctl, with XTWINOPS fallback) — needed for the size
    # line and the aspect ratio fed to layout.
    screen.detect_cell_geometry
  end

  emu = tput.emulator
  f = tput.features

  # --- JSON mode: identity + the full detection map, machine-readable. --------
  if json
    puts({
      identity: {
        terminal:      emu.identity,
        version:       emu.version,
        multiplexer:   emu.multiplexer,
        self_reported: emu.self_reported?,
        probed:        f.probed?,
        term:          tput.name,
        aliases:       tput.aliases,
        cols:          screen.width,
        rows:          screen.height,
        cell_px_w:     screen.cell_pixel_width,
        cell_px_h:     screen.cell_pixel_height,
        colors:        screen.colors,
        truecolor:     screen.truecolor?,
        unicode:       f.unicode?,
        graphics:      emu.best_graphics.to_s,
      },
      detections: tput.detections,
    }.to_pretty_json)
    exit 0
  end

  # Small aligned printer: name / value / how-it-was-determined, matching
  # `Tput#dump`'s layout.
  section = ->(title : String, rows : Array({String, String, String})) {
    puts title
    nw = rows.max_of(&.[0].size)
    vw = rows.max_of(&.[1].size)
    rows.each { |name, value, note| puts "  #{name.ljust(nw)}  #{value.ljust(vw)}  #{note}" }
  }

  # --- VERDICT: the one-line answer first, then the supporting dimensions. -----
  ident = emu.identity || "(unidentified)"
  ident += " #{emu.version}" if emu.version
  how = emu.self_reported? ? "XTVERSION self-report" : "env/TERM heuristic"

  size = "#{screen.width} x #{screen.height} cells"
  if screen.cell_pixel_width > 0
    size += "  (cell #{screen.cell_pixel_width} x #{screen.cell_pixel_height} px"
    size += ", window #{screen.width * screen.cell_pixel_width} x #{screen.height * screen.cell_pixel_height} px)"
  end

  color = screen.truecolor? ? "16M (truecolor)" : "#{screen.colors}"

  kbd = [] of String
  kbd << "kitty keyboard protocol" if f.kitty_keyboard?
  kbd << "modifyOtherKeys=#{f.modify_other_keys}" if f.modify_other_keys?
  kbd_s = kbd.empty? ? "legacy only" : kbd.join(", ")

  cursor = [] of String
  cursor << "styleable" if f.cursor_style?
  cursor << "recolorable" if f.cursor_color?
  cursor_s = cursor.empty? ? "default only" : cursor.join(", ")

  rows = [
    {"terminal", ident, how},
  ]
  rows << {"multiplexer", emu.multiplexer.not_nil!, "running inside a multiplexer"} if emu.multiplexer
  rows.concat [
    {"TERM", tput.name, tput.aliases.empty? ? "" : "aliases: #{tput.aliases.join(", ")}"},
    {"size", size, screen.cell_pixel_width > 0 ? "ioctl / XTWINOPS" : "cells only (no pixel size reported)"},
    {"color", color, f.sources["number_of_colors"]? || ""},
    {"unicode", f.unicode? ? "yes" : "no", f.sources["unicode"]? || ""},
    {"graphics", emu.best_graphics.to_s, "in-band image protocol"},
    {"keyboard", kbd_s, "enhanced key reporting"},
    {"cursor", cursor_s, "hardware cursor shape / color"},
  ]

  puts "TERMINAL IDENTIFICATION"
  unless f.probed?
    puts no_probe ? "  (probing disabled — identity from environment/terminfo only)" : "  (not a terminal — identity from environment/terminfo only)"
  end
  puts
  section.call "VERDICT", rows
  puts

  # --- EVIDENCE: the full per-setting breakdown with provenance. --------------
  tput.dump STDOUT

  if verbose
    # Renders a raw capability byte string (e.g. smacs/el) readably.
    esc = ->(b : Bytes) { b.empty? ? "(none)" : String.new(b).inspect }

    puts
    section.call "CRYSTERM (rendering — derived on top of Tput)", [
      {"size", "#{screen.width} x #{screen.height}",
       screen.explicit_size? ? "explicit (constructor)" : "probed from terminal"},
      {"colors", screen.colors.to_s,
       "effective depth; policy #{Config.screen_color_force} / #{Config.colors_depth}, tput detected #{f.number_of_colors}"},
      {"truecolor", screen.truecolor?.to_s, "effective (colors >= 16M)"},
      {"force_unicode", screen.force_unicode?.to_s, "Crysterm option (screen.force_unicode)"},
      {"full_unicode (requested)", screen.full_unicode?.to_s, "Crysterm option (screen.full_unicode)"},
      {"full_unicode (effective)", screen.full_unicode_effective?.to_s, "option AND terminal unicode (#{f.unicode?})"},
      {"hardware_cursor_styling", screen.hardware_cursor_styling?.to_s, "from Tput cursor_style (DECSCUSR / OSC 50)"},
      {"hardware_cursor_color", screen.hardware_cursor_color?.to_s, "from Tput cursor_color (OSC 12)"},
      {"cell_pixels", "#{screen.cell_pixel_width} x #{screen.cell_pixel_height}",
       screen.cell_pixel_width > 0 ? "detected (ioctl / XTWINOPS)" : "terminal reported none"},
      {"cell_aspect_ratio", CSS::Length.cell_aspect_ratio.to_s,
       CSS::Length.cell_aspect_ratio_configured? ? "pinned (css.cell_aspect_ratio)" : "derived from cell_pixels (default 2.0)"},
      {"headless", Crysterm.headless?.to_s, "no real tty / IO redirected"},
    ]
    puts

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
