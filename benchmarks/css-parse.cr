require "../src/crysterm"

# Cost of `CSS::Stylesheet.parse` as a function of sheet size and content.
# The parser scans for ASCII delimiters; indexing the sheet by *character*
# is O(index) once the text holds any non-ASCII character (a glyph value
# such as `glyph: "▶"`), which makes a whole-sheet scan quadratic.
#
#   * theme        — the built-in default theme's CSS text;
#   * ascii NK     — a synthetic N KB sheet of ordinary ASCII rules;
#   * glyph NK     — the same sheet with a single non-ASCII glyph value in
#                    its last rule.
#
# Run:  crystal run --release benchmarks/css-parse.cr

alias CT = Crysterm

def synthetic(kb : Int32, glyph : Bool) : String
  String.build do |io|
    i = 0
    while io.bytesize < kb * 1024
      io << ".cls" << i << " > Button:hover, Box#id" << i << " Label[data-x=\"a;b\"] {\n"
      io << "  color: #aabbcc;\n  background-color: rgb(10, 20, 30);\n  border: 1;\n  padding: 0 1;\n}\n"
      i += 1
    end
    io << "CheckBox::indicator { glyph: \"▶\"; }\n" if glyph
  end
end

def bench(label : String, css : String, rounds : Int32) : Nil
  sheet = CT::CSS::Stylesheet.parse css # warm
  GC.collect
  b0 = GC.stats.total_bytes
  t0 = Time.instant
  rounds.times { CT::CSS::Stylesheet.parse css }
  dt = (Time.instant - t0).total_milliseconds / rounds
  db = (GC.stats.total_bytes - b0) / rounds / 1024.0
  printf "  %-12s %7d B  %6d rules  %10.3f ms/parse  %9.1f KiB/parse\n", label, css.bytesize, sheet.rules.size, dt, db
end

theme = CT::CSS::Theme.dark.to_css
bench "theme", theme, 20
puts "  (theme text is #{theme.ascii_only? ? "ASCII-only" : "not ASCII-only"})"
{15, 60, 240}.each do |kb|
  bench "ascii #{kb}K", synthetic(kb, false), 5
  bench "glyph #{kb}K", synthetic(kb, true), (kb > 60 ? 1 : 3)
end
