require "./spec_helper"

include Crysterm

# Differential coverage for the dirty-column scan bound in `Window#draw` under
# `full_unicode`.
#
# The per-row diff may scan only `[dirty_min - straddle, dirty_max + 1]`
# instead of the full row width. That bound must be *invisible*: for identical
# cell content and the same set of dirty rows, the emitted terminal bytes and
# the resulting `@flushed_lines` state must be byte-for-byte equal to an
# unbounded (full-width) scan. Wide graphemes make this non-trivial — a glyph
# couples its lead and continuation cell across the range edge.
#
# Oracle: every scenario runs twice on identical windows — once with the
# writers' own narrow `mark_dirty(x)` ranges, once with each dirty row widened
# to a full-width range (`dirty = true`, which disables the bound) — and the
# frame bytes plus the full flushed state are compared.

# Public spec-only surface over the protected `#draw`: the top-level
# `include Crysterm` trick that lets sibling specs call it directly does not
# reach into defs carrying a proc-typed parameter restriction (`fu_frame`
# below), so the call is routed through the class itself.
class Crysterm::Window
  def spec_draw_frame
    draw
  end

  # Renders the widget tree into `lines` without drawing, so a scenario can
  # widen the dirty ranges between the two phases — `repaint` fuses them.
  def spec_composite_frame
    damage_full_composite
  end
end

private def fu_bound_screen(output, width = 30, height = 5)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: width, height: height)
  s.full_unicode = true
  s.alloc
  s
end

# Serializes the complete flushed-buffer state — attr, base codepoint,
# grapheme overlay and link id of every cell — so two runs can be compared for
# state equivalence, not just for emitted bytes.
private def flushed_dump(s) : String
  String.build do |io|
    s.flushed_lines.each do |row|
      row.size.times do |x|
        c = row[x]
        io << c.attr << ',' << c.char.ord << ',' << (c.grapheme_overlay || "") << ',' << c.link << ';'
      end
      io << '\n'
    end
  end
end

# Runs one scenario frame pair: *setup* builds frame 1 (drawn with every row
# fully dirty, priming `@flushed_lines`), then *mutate* applies frame 2's
# changes using real writers (whose `mark_dirty(x)` calls narrow the range).
# With *widen*, every dirty row is widened to a full-width range before the
# draw, producing the unbounded reference scan. Returns frame 2's bytes and
# the final flushed state.
private def fu_frame(widen : Bool, width = 30, height = 5, *,
                     setup : Crysterm::Window -> = ->(_s : Crysterm::Window) { },
                     mutate : Crysterm::Window ->) : {String, String}
  buf = IO::Memory.new
  s = fu_bound_screen buf, width, height
  setup.call s
  s.cell_rows.each(&.dirty=(true))
  s.spec_draw_frame
  buf.clear
  mutate.call s
  s.cell_rows.each { |l| l.dirty = true if l.dirty } if widen
  s.spec_draw_frame
  {String.new(buf.to_slice), flushed_dump(s)}
end

# Fills row *y* with `pattern` repeated, via the real cell writers (marks the
# whole row through `set_if_changed`).
private def fill_row(s, y, pattern : String, attr = 0_i64)
  line = s.cell_rows[y]
  line.size.times do |x|
    line[x].set_if_changed attr, pattern[x % pattern.size]
  end
end

describe "Window#draw dirty-column bound under full_unicode" do
  red = Attr.pack(0_i64, Attr.pack_color(0xFF0000), Attr.pack_color(0x000000))
  blue = Attr.pack(0_i64, Attr.pack_color(0x0000FF), Attr.pack_color(0x000000))

  # Each entry: {setup, mutate}. All writers below mark dirty columns narrowly
  # (directly or via `set_if_changed`/`put_wide`/`Cell#link=`), which is
  # exactly what the bounded scan consumes.
  scenarios = {
    "narrow change mid-row inside unchanged text" => {
      ->(s : Crysterm::Window) { fill_row s, 2, "abcdefghij" },
      ->(s : Crysterm::Window) { s.cell_rows[2][14].set_if_changed red, 'X' },
    },
    "changes at row start and row end" => {
      ->(s : Crysterm::Window) { fill_row s, 1, "qrstu" },
      ->(s : Crysterm::Window) {
        s.cell_rows[1][0].set_if_changed red, 'L'
        s.cell_rows[1][29].set_if_changed blue, 'R'
      },
    },
    "wide glyph placed mid-row" => {
      ->(s : Crysterm::Window) { fill_row s, 2, "x" },
      ->(s : Crysterm::Window) { s.put_wide red, '漢', 10, 2 },
    },
    "wide glyph at the last two columns" => {
      ->(s : Crysterm::Window) { fill_row s, 3, "y" },
      ->(s : Crysterm::Window) { s.put_wide blue, '字', 28, 3 },
    },
    "lead-only attr change on an existing wide glyph (right straddle)" => {
      ->(s : Crysterm::Window) {
        fill_row s, 2, "m"
        s.put_wide 0_i64, '漢', 12, 2
      },
      ->(s : Crysterm::Window) {
        line = s.cell_rows[2]
        line[12].attr = red
        line.mark_dirty 12
      },
    },
    "continuation-only attr change on an existing wide glyph (left straddle)" => {
      ->(s : Crysterm::Window) {
        fill_row s, 1, "n"
        s.put_wide 0_i64, '漢', 8, 1
      },
      ->(s : Crysterm::Window) {
        line = s.cell_rows[1]
        line[9].attr = blue
        line.mark_dirty 9
        # A second change later in the row exercises the reposition after the
        # orphan-continuation emit (which forces an absolute cursor move).
        line[15].set_if_changed red, 'Z'
      },
    },
    "wide glyph overwritten by narrow text" => {
      ->(s : Crysterm::Window) {
        fill_row s, 2, "p"
        s.put_wide red, '漢', 6, 2
      },
      ->(s : Crysterm::Window) {
        s.cell_rows[2][6].set_if_changed 0_i64, 'a'
        s.cell_rows[2][7].set_if_changed 0_i64, 'b'
      },
    },
    "adjacent wide glyphs with a narrow change between" => {
      ->(s : Crysterm::Window) {
        fill_row s, 3, "k"
        s.put_wide 0_i64, '漢', 4, 3
        s.put_wide 0_i64, '字', 8, 3
      },
      ->(s : Crysterm::Window) {
        s.cell_rows[3][6].set_if_changed red, 'Q'
        s.cell_rows[3][7].set_if_changed red, 'W'
      },
    },
    "orphan continuation at column 0 (clipped lead)" => {
      ->(s : Crysterm::Window) {
        fill_row s, 0, "c"
        line = s.cell_rows[0]
        line[0].continuation!
        line.mark_dirty 0
      },
      ->(s : Crysterm::Window) {
        line = s.cell_rows[0]
        line[0].attr = red
        line.mark_dirty 0
        line[5].set_if_changed blue, 'D'
      },
    },
    "grapheme cluster change with same base char and attr" => {
      ->(s : Crysterm::Window) {
        fill_row s, 1, "e"
      },
      ->(s : Crysterm::Window) {
        line = s.cell_rows[1]
        line[7].grapheme = "e\u{0301}"
        line.mark_dirty 7
      },
    },
    "link-only change mid-row" => {
      ->(s : Crysterm::Window) { fill_row s, 2, "link text " },
      ->(s : Crysterm::Window) {
        id = s.link_id "http://example.com/a"
        s.cell_rows[2][11].link = id
        nil
      },
    },
    "linked wide glyph" => {
      ->(s : Crysterm::Window) { fill_row s, 3, "t" },
      ->(s : Crysterm::Window) {
        s.put_wide red, '漢', 16, 3
        id = s.link_id "http://example.com/wide"
        s.cell_rows[3][16].link = id
        s.cell_rows[3][17].link = id
        nil
      },
    },
    "contiguous run marked via mark_dirty_range (media-style row sweep)" => {
      ->(s : Crysterm::Window) { fill_row s, 2, "sweep this " },
      ->(s : Crysterm::Window) {
        line = s.cell_rows[2]
        (8..19).each do |x|
          line[x].attr = red
          line[x].char = '#'
        end
        line.mark_dirty_range 8, 19
      },
    },
    "run cleared back to blanks" => {
      ->(s : Crysterm::Window) { fill_row s, 2, "clear me please and thanks" },
      ->(s : Crysterm::Window) { s.clear_region 5, 15, 2, 3 },
    },
    "sparse changes across several rows" => {
      ->(s : Crysterm::Window) {
        fill_row s, 0, "0"
        fill_row s, 2, "2"
        fill_row s, 4, "4"
      },
      ->(s : Crysterm::Window) {
        s.cell_rows[0][3].set_if_changed red, 'A'
        s.put_wide blue, '漢', 20, 2
        s.cell_rows[4][27].set_if_changed red, 'B'
      },
    },
  }

  scenarios.each do |name, (setup, mutate)|
    it "bounded scan is byte- and state-equivalent to full scan: #{name}" do
      probe = fu_bound_screen IO::Memory.new
      pending! "full_unicode unavailable in this environment" unless probe.full_unicode_effective?

      narrow = fu_frame(false, setup: setup, mutate: mutate)
      full = fu_frame(true, setup: setup, mutate: mutate)
      narrow[0].should eq full[0]
      narrow[1].should eq full[1]
    end
  end

  it "produces actual output (guards against the no-op trap)" do
    probe = fu_bound_screen IO::Memory.new
    pending! "full_unicode unavailable in this environment" unless probe.full_unicode_effective?

    setup = ->(s : Crysterm::Window) { fill_row s, 2, "x" }
    mutate = ->(s : Crysterm::Window) { s.put_wide 0_i64, '漢', 10, 2 }
    fu_frame(false, setup: setup, mutate: mutate)[0].size.should be > 0
  end

  # Widget-level differentials: a full composite (buffer clear + widget
  # re-render) between the two frames drives the converted widget writers —
  # `Table#draw_borders`/`recolor_cells` and `Mixin::EmulatorBlit` — whose
  # narrow `mark_dirty` ranges the bounded second draw then consumes.

  it "table border repaint: bounded scan is byte- and state-equivalent" do
    probe = fu_bound_screen IO::Memory.new
    pending! "full_unicode unavailable in this environment" unless probe.full_unicode_effective?

    tables = [] of Crysterm::Widget::Table
    setup = ->(s : Crysterm::Window) {
      tables << Crysterm::Widget::Table.new(parent: s, left: 1, top: 0,
        rows: [["Name", "Qty"], ["ab", "1"], ["cd", "2"]],
        style: Crysterm::Style.new(border: true))
      s.spec_composite_frame
    }
    mutate = ->(s : Crysterm::Window) {
      tables.last.rows = [["Name", "Qty"], ["ab", "1"], ["zzzz", "99"]]
      s.spec_composite_frame
    }

    narrow = fu_frame(false, 34, 12, setup: setup, mutate: mutate)
    full = fu_frame(true, 34, 12, setup: setup, mutate: mutate)
    narrow[0].size.should be > 0
    narrow[0].should eq full[0]
    narrow[1].should eq full[1]
  end

  it "emulator blit (LogFd :ansi, wide glyphs): bounded scan is byte- and state-equivalent" do
    probe = fu_bound_screen IO::Memory.new
    pending! "full_unicode unavailable in this environment" unless probe.full_unicode_effective?

    fds = [] of Crysterm::Widget::LogFd
    setup = ->(s : Crysterm::Window) {
      fd = Crysterm::Widget::LogFd.new(io: IO::Memory.new(""), mode: :ansi,
        parent: s, top: 1, left: 2, width: 20, height: 4)
      fds << fd
      # First composite sizes and attaches the emulator; the feed lands in the
      # emulator grid only, so frame 2's composite blits it with narrow marks.
      s.spec_composite_frame
      fd.feed "\e[31mAB漢"
      nil
    }
    mutate = ->(s : Crysterm::Window) {
      fds.last.feed "\r\n\e[36mXY字"
      s.spec_composite_frame
    }

    begin
      narrow = fu_frame(false, 30, 8, setup: setup, mutate: mutate)
      full = fu_frame(true, 30, 8, setup: setup, mutate: mutate)
      narrow[0].size.should be > 0
      narrow[0].should eq full[0]
      narrow[1].should eq full[1]
    ensure
      fds.each &.close
    end
  end

  it "BCE optimization still forces the full-width scan (bytes unaffected by narrowing)" do
    probe = fu_bound_screen IO::Memory.new
    pending! "full_unicode unavailable in this environment" unless probe.full_unicode_effective?

    setup = ->(s : Crysterm::Window) {
      s.optimization = OptimizationFlag::BCE
      fill_row s, 2, "wipe this row tail entirely!"
    }
    mutate = ->(s : Crysterm::Window) { s.clear_region 4, 30, 2, 3 }
    narrow = fu_frame(false, setup: setup, mutate: mutate)
    full = fu_frame(true, setup: setup, mutate: mutate)
    narrow[0].should eq full[0]
    narrow[1].should eq full[1]
  end
end
