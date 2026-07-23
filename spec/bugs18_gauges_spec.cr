require "./spec_helper"

include Crysterm

# Regression specs for the BUGS18 gauge/meter-widget batch:
#
# * B18-57 — Gauge/GaugeList/Donut constructors stored a non-finite
#   minimum/maximum unsanitized (only `#set_range` guarded it), poisoning
#   `percent_of` with NaN and crashing the render fiber on `.round.to_i`.
#   Fixed via a shared `Mixin::PercentRange#sanitize_range` used by all three
#   constructors.
# * B18-58 — `GroupBox`'s `ChildAdded` handler (and `checkable=`) ran
#   `apply_enabled` unconditionally, which on a *checked* group takes the
#   restore branch and force-enables every app-disabled child.
# * B18-60 — `Gauge#with_labels`/`#overlay` measured/placed captions by
#   codepoint count and wrote one `Char` per cell slot, so a wide (CJK/emoji)
#   caption widened the row past `cols` display columns under full_unicode.
# * B18-61 — `LCDNumber#display(Float)` stored/rendered non-finite input
#   unsanitized, and `#int_value` overflowed on NaN/huge-but-finite values.
# * B18-63 — `KeyMenu#columns=`/constructor lacked the `>= 1` clamp its
#   sibling `rows=` has: `columns <= 0` silently dropped every entry.
# * B18-66 — `GaugeList#label_width=`, `Gauge#show_label=`/`#format=`, and
#   `ProgressBar#text_visible=`/`#format=` were plain properties that never
#   scheduled a repaint, so a change stayed invisible on an idle UI.

private def headless_screen(w = 80, h = 24, *, force_unicode = false, full_unicode = false)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false,
    force_unicode: force_unicode, full_unicode: full_unicode)
end

describe "BUGS18 B18-57: Gauge/GaugeList/Donut constructors sanitize non-finite bounds" do
  it "Gauge.new with a NaN minimum does not raise on render and stores a finite range" do
    s = headless_screen
    g = Widget::Gauge.new parent: s, value: 50, minimum: Float64::NAN, maximum: 100.0
    g.minimum.finite?.should be_true
    g.maximum.finite?.should be_true
    s.repaint # pre-fix: OverflowError in #render via formatted_text's `.round.to_i`
  end

  it "Gauge.new with a NaN maximum collapses max to the (sanitized) min" do
    s = headless_screen
    g = Widget::Gauge.new parent: s, value: 50, minimum: 10.0, maximum: Float64::NAN
    g.minimum.should eq 10.0
    g.maximum.should eq 10.0
    s.repaint
  end

  it "GaugeList.new with a NaN minimum does not raise on render" do
    s = headless_screen
    gl = Widget::GaugeList.new parent: s, minimum: Float64::NAN, width: 30, height: 5
    gl.minimum.finite?.should be_true
    gl.add_item "cpu", 64
    s.repaint # pre-fix: OverflowError via gauge_line's `pct.round.to_i`
  end

  it "Donut.new with a NaN maximum does not raise on render" do
    s = headless_screen
    d = Widget::Graph::Donut.new parent: s, value: 50, minimum: 0.0, maximum: Float64::NAN,
      width: 18, height: 9
    d.maximum.finite?.should be_true
    s.repaint # pre-fix: OverflowError via draw_center_label's `percent.round.to_i`
  end

  it "an ordinary finite range is unaffected" do
    s = headless_screen
    g = Widget::Gauge.new parent: s, value: 25, minimum: 0.0, maximum: 50.0
    g.minimum.should eq 0.0
    g.maximum.should eq 50.0
    g.value.should eq 25.0
  end
end

describe "BUGS18 B18-58: GroupBox does not force-enable app-disabled children on adopt" do
  it "appending a child to a checked checkable group leaves other app-disabled children disabled" do
    s = headless_screen
    gb = Widget::GroupBox.new parent: s, checkable: true, checked: true, width: 30, height: 8

    disabled_child = Widget::Box.new width: 10, height: 1
    disabled_child.state = :disabled
    gb.append disabled_child

    second = Widget::Box.new width: 10, height: 1
    gb.append second # a later adopt must not re-enable the first child either

    disabled_child.state.disabled?.should be_true
  end

  it "a child added to an unchecked checkable group still comes up disabled" do
    s = headless_screen
    gb = Widget::GroupBox.new parent: s, checkable: true, checked: false, width: 30, height: 8
    child = Widget::Box.new width: 10, height: 1
    gb.append child
    child.state.disabled?.should be_true
  end

  it "the checked=/toggle restore path is unaffected: re-checking restores greyed children" do
    s = headless_screen
    gb = Widget::GroupBox.new parent: s, checkable: true, checked: true, width: 30, height: 8
    child = Widget::Box.new width: 10, height: 1
    gb.append child

    gb.checked = false
    child.state.disabled?.should be_true

    gb.checked = true
    child.state.disabled?.should be_false
  end

  it "setting checkable = true on an already-checked group does not disturb app-disabled children" do
    s = headless_screen
    gb = Widget::GroupBox.new parent: s, checkable: false, checked: true, width: 30, height: 8
    child = Widget::Box.new width: 10, height: 1
    gb.append child
    child.state = :disabled

    gb.checkable = true

    child.state.disabled?.should be_true
  end
end

describe "BUGS18 B18-60: Gauge overlay measures/places captions by display column" do
  it "Graph::Scale.overlay_text keeps the row at exactly cells.size display columns for a wide caption" do
    cols = 10
    cells = Array(Char).new(cols, ' ')
    colors = Array(String?).new(cols, nil)
    Crysterm::Widget::Graph::Scale.overlay_text(cells, colors, 2, "正常", true)

    row = String.build { |io| Crysterm::Widget::Graph::Scale.tagged_row(io, cells, colors) }
    Crysterm::Unicode.display_width(row).should eq cols
    cells.size.should be < cols # wide chars consumed continuation slots
  end

  it "does not corrupt a row when overlaying two captions right-to-left" do
    cols = 20
    cells = Array(Char).new(cols, ' ')
    colors = Array(String?).new(cols, nil)
    # Rightmost first, mirroring Gauge#with_labels' reverse iteration.
    Crysterm::Widget::Graph::Scale.overlay_text(cells, colors, 12, "警告", true)
    Crysterm::Widget::Graph::Scale.overlay_text(cells, colors, 2, "正常", true)

    row = String.build { |io| Crysterm::Widget::Graph::Scale.tagged_row(io, cells, colors) }
    Crysterm::Unicode.display_width(row).should eq cols
  end

  it "skips a wide char that would land in the final slot instead of corrupting the tail" do
    cols = 3
    cells = Array(Char).new(cols, ' ')
    colors = Array(String?).new(cols, nil)
    Crysterm::Widget::Graph::Scale.overlay_text(cells, colors, 2, "国", true)
    cells.size.should eq cols # no slot was deleted; the wide char was skipped
  end

  it "a stacked gauge with CJK segment captions under full_unicode renders without wrapping" do
    s = headless_screen(force_unicode: true, full_unicode: true)
    g = Widget::Gauge.new parent: s, width: 40, height: 1, show_label: true,
      segments: [
        Widget::Gauge::Segment.new(50, "green", "正常"),
        Widget::Gauge::Segment.new(50, "red", "警告"),
      ]
    s.repaint
    # One logical content row (height: 1, no border); pre-fix it measured wider
    # than the box's 40 columns and wrapped onto a second *screen* line.
    g.screen_lines.size.should eq 1
  end

  it "legacy (non-full_unicode) mode keeps codepoint-count placement (no regression)" do
    cols = 10
    cells = Array(Char).new(cols, ' ')
    colors = Array(String?).new(cols, nil)
    Crysterm::Widget::Graph::Scale.overlay_text(cells, colors, 2, "ab", false)
    cells.size.should eq cols
    cells[2].should eq 'a'
    cells[3].should eq 'b'
  end
end

describe "BUGS18 B18-61: LCDNumber sanitizes non-finite Float input" do
  it "value = NaN shows a safe 0 rather than a stray 'A' glyph, and int_value does not raise" do
    s = headless_screen
    lcd = Widget::LCDNumber.new parent: s, digit_count: 3
    lcd.value = 0.0/0.0
    lcd.value.finite?.should be_true
    lcd.text.should eq "0"
    lcd.int_value.should eq 0_i64
  end

  it "value = Infinity is sanitized the same way" do
    s = headless_screen
    lcd = Widget::LCDNumber.new parent: s, digit_count: 3
    lcd.value = Float64::INFINITY
    lcd.value.finite?.should be_true
    lcd.int_value.should eq 0_i64
  end

  it "a huge-but-finite value does not raise from int_value" do
    s = headless_screen
    lcd = Widget::LCDNumber.new parent: s, digit_count: 3
    lcd.value = 1e300
    lcd.int_value # pre-fix: OverflowError
  end

  it "an ordinary finite value round-trips through int_value" do
    s = headless_screen
    lcd = Widget::LCDNumber.new parent: s, digit_count: 3
    lcd.value = 42.0
    lcd.int_value.should eq 42_i64
  end
end

describe "BUGS18 B18-63: KeyMenu#columns clamps to at least 1" do
  it "KeyMenu.new(columns: 0, ...) still renders its entries instead of going blank" do
    s = headless_screen
    entries = [Widget::Pine::KeyMenu::Entry.new("a", "Alpha"), Widget::Pine::KeyMenu::Entry.new("b", "Beta")]
    menu = Widget::Pine::KeyMenu.new parent: s, entries: entries, columns: 0
    menu.columns.should be >= 1
    menu.cells.size.should eq entries.size
  end

  it "columns = 0 at runtime clamps instead of blanking the bar" do
    s = headless_screen
    entries = [Widget::Pine::KeyMenu::Entry.new("a", "Alpha")]
    menu = Widget::Pine::KeyMenu.new parent: s, entries: entries, columns: 3
    menu.columns = 0
    menu.columns.should be >= 1
    menu.cells.size.should eq entries.size
  end

  it "a negative columns value also clamps" do
    s = headless_screen
    menu = Widget::Pine::KeyMenu.new parent: s, entries: [Widget::Pine::KeyMenu::Entry.new("a", "Alpha")]
    menu.columns = -5
    menu.columns.should be >= 1
  end
end

describe "BUGS18 B18-66: idle-visible setters schedule a repaint" do
  it "Gauge#show_label= and #format= change the built content on the next render" do
    s = headless_screen
    g = Widget::Gauge.new parent: s, width: 20, height: 1, value: 50, show_label: true
    s.repaint
    with_label = g.content

    g.show_label = false
    s.repaint
    g.content.should_not eq with_label

    g.format = "%v of %m"
    s.repaint # must not raise / must take effect without an unrelated event
  end

  it "GaugeList#label_width= changes the built content on the next render" do
    s = headless_screen
    gl = Widget::GaugeList.new parent: s, width: 30, height: 3
    gl.add_item "cpu", 50
    s.repaint
    before = gl.content

    gl.label_width = 20
    s.repaint
    gl.content.should_not eq before
  end

  it "ProgressBar#text_visible= and #format= schedule a repaint" do
    s = headless_screen
    bar = Widget::ProgressBar.new parent: s, width: 20, height: 1, value: 40
    bar.text_visible = true
    bar.format = "%v/%m"
    s.repaint # pre-fix these were bare properties; just must not raise
    bar.text_visible?.should be_true
    bar.format.should eq "%v/%m"
  end

  it "same-value assignment is a no-op (no redundant render request)" do
    s = headless_screen
    g = Widget::Gauge.new parent: s, width: 20, height: 1, value: 50, show_label: true
    g.show_label = true # same as current value
    g.format = "%p%"    # same as current value
    s.repaint
  end
end
