require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def sized_screen(width, height)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false)
end

# BUGS12 #12 — `delete_line` clamped the index against `ftor` and, when `ftor`
# was empty but `fake` non-empty (content seeded before attach), landed on `-1`
# and deleted the LAST line (Crystal's two-arg `clamp` returns `max` when
# `min > max`). It now clamps against `fake`, the array actually spliced.
# Reproduce the exact internal state the finding describes: `fake` populated,
# `ftor` empty. `set_content` fills both; clearing `ftor` just before the delete
# mimics content that was seeded before the widget could wrap it.
private def box_with_empty_ftor
  box = Widget::Box.new parent: headless_screen, width: 20, height: 5
  box.set_content "one\ntwo\nthree"
  box.lines.should eq ["one", "two", "three"] # precondition
  box.@_clines.ftor.clear
  box
end

describe "Widget#delete_line with ftor empty (content seeded before attach)" do
  it "deletes the requested line, not the last one" do
    box = box_with_empty_ftor
    box.delete_line 0
    box.lines.should eq ["two", "three"]
  end

  it "defaults delete_line(nil) to the last fake line" do
    box = box_with_empty_ftor
    box.delete_line
    box.lines.should eq ["one", "two"]
  end

  it "does not overrun (IndexError) when n exceeds the lines available from i" do
    box = box_with_empty_ftor
    # With i clamped to -1 and `n = min(n, fake.size - i)`, this ran delete_at
    # off the end of `fake`.
    box.delete_line 0, 5
    box.lines.should eq [] of String
  end
end

# BUGS12 #13 — `rebuild_content_from_fake` called `set_content(joined, true)`,
# letting `no_tags` default to false and permanently flipping a literal-tags
# widget back into tag-parsing mode. It now forwards `@_content_no_tags`.
describe "Widget#rebuild_content_from_fake preserves no_tags mode" do
  it "keeps tags literal after a fake-array rebuild (delete_line)" do
    box = Widget::Box.new parent: headless_screen, width: 20, height: 5
    box.parse_tags = true
    box.set_text("{bold}a{/bold}\nplain")

    box.pcontent.should contain "{bold}"
    box.pcontent.should_not contain "\e["

    # delete_line rebuilds content from the fake array.
    box.delete_line 1
    box.process_content

    box.pcontent.should contain "{bold}"
    box.pcontent.should_not contain "\e["
  end

  it "keeps tags literal after set_line" do
    box = Widget::Box.new parent: headless_screen, width: 20, height: 5
    box.parse_tags = true
    box.set_text("{bold}a{/bold}")

    box.set_line 0, "{red-fg}z{/red-fg}"
    box.process_content

    box.pcontent.should contain "{red-fg}"
    box.pcontent.should_not contain "\e["
  end
end

# BUGS12 #14 — `Effect::Direct#paint` looped from 0 using `lines[yi + ry]?` /
# `line[xi + rx]?` with possibly-negative absolute coords. `Row`/`lines` are
# `Indexable`, so negative indices wrap to the end, corrupting the bottom/right
# of the terminal. The loops now start past the offscreen band.
describe "Effect::Direct#paint clips the off-top/left band" do
  it "does not paint wrapped bottom/right rows when partly off the top-left" do
    s = sized_screen 12, 12
    s.alloc

    # Positioned so xi/yi are negative — part of the box is off the top-left.
    p = Crysterm::Widget::Effect::Plasma.new(
      parent: s, left: -3, top: -3, width: 8, height: 8, glyph: '#')
    s._render

    # The bottom and right edges of the buffer must remain untouched (a
    # negative-index wrap would have stamped the plasma glyph there).
    (0...12).each do |x|
      s.lines[11][x].char.should_not eq '#'
    end
    (0...12).each do |y|
      s.lines[y][11].char.should_not eq '#'
    end

    p # keep referenced
  end
end

# BUGS12 #23 — the `\n` row-fill branch painted the row tail with `bch`
# unconditionally, ignoring `fill: false` (which the pre-fill, exhausted-content
# and per-cell paths all honor). It now advances the column without painting,
# mirroring the `bg_cells` branch, so a transparent widget stays transparent.
describe "Widget newline row-fill honors fill: false" do
  it "leaves the newline tail transparent over a backdrop" do
    s = sized_screen 20, 8

    # Solid red backdrop.
    Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 8,
      style: Crysterm::Style.new(bg: "red")

    st = Crysterm::Style.new
    st.fill = false
    # Content with an embedded newline: row 0 = "ab", then the newline branch
    # fills the rest of that row.
    b = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 6, height: 3,
      style: st, content: "ab\ncd"
    s._render

    lp = b.lpos.not_nil!
    # Reference the backdrop from just OUTSIDE the box (col == lp.xl), which the
    # transparent widget never touches.
    red = Crysterm::Attr.bg(s.lines[lp.yi][lp.xl].attr)

    # A tail cell after "ab" on row 0 (inside the box, in the newline-fill zone)
    # must still show the red backdrop, not the widget's own fill.
    tail_bg = Crysterm::Attr.bg(s.lines[lp.yi][lp.xi + 3].attr)
    tail_bg.should eq red
    # And a row with no newline-fill (row 1, "cd") must match too — sanity that
    # `red` really is the backdrop color.
    Crysterm::Attr.bg(s.lines[lp.yi + 1][lp.xi + 3].attr).should eq red
  end
end
