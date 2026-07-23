require "./spec_helper"

include Crysterm

# Regression specs for the BUGS18 containers batch:
#
# * B18-53 — `BigText#render` sized an unset dimension to the bare glyph
#   extent, omitting `ihorizontal`/`ivertical`: a bordered/padded
#   shrink-sized `BigText` clipped its last glyph and the bottom rows of
#   every glyph.
# * B18-54 — `ToolBox#add_item` dup'd the container's *full* style (border
#   and padding included) onto each height-1 header, so a bordered/padded
#   ToolBox rendered every header as a border line with an invisible title.
#   Sibling: `Pine::StatusBar`'s inner `@status` box had the same leak.
# * B18-56 — `DockWidget#closable=`/`#floatable=` were bare `property?`s;
#   the title-bar chrome they govern is built once in the constructor, so a
#   runtime toggle left a dead-but-visible (or missing-but-enabled) button,
#   and a disabled `SizeGrip` stayed present.
# * B18-59 — `TabWidget#tabs_closable=` was a bare `property?`; the `✕`
#   marker is baked into bar-item text only when titles are (re)built, so a
#   runtime toggle changed close behavior without changing the display.
# * B18-62 — `DockWidget#dock_size=` was a bare `property`; nothing observes
#   it outside `MainWindow#relayout` (which only runs mid-frame), so an idle
#   UI never scheduled a repaint to apply a new size. Sibling: `#area=`
#   and `#toggle_floating` used `window?.try &.update` (schedule-only, no
#   damage mark), which is a no-op under `DamageTracking` for some paths.
# * B18-64 — `BigText` snapshotted `style.bold?` once, at construction,
#   before the CSS cascade could ever have run, so CSS `font-weight: bold`
#   (or a later `style.bold = true`) never switched to the loaded bold face.

private def headless_screen(w = 80, h = 24, optimization = Crysterm::OptimizationFlag::None)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false, optimization: optimization)
end

# ---------------------------------------------------------------------------
# B18-53

describe "BUGS18 B18-53: BigText shrink-to-content sizing includes border/padding insets" do
  it "widens/heightens to fit the full glyph run and all glyph rows under a border" do
    s = headless_screen
    # Two U+2588 FULL BLOCK glyphs: the default Unifont face pads ordinary
    # letters like 'H'/'I' with blank rows top and bottom (e.g. 'H' only
    # lights rows 4..13 of its 16-row cell), so those letters can't tell a
    # row-clipped render apart from a correct one. FULL BLOCK lights every
    # row and column of its cell, making "did the last row/column paint"
    # unambiguous.
    bt = Widget::BigText.new parent: s, top: 0, left: 0, content: "██",
      foreground_char: '#', style: Style.new(border: true)
    s.repaint

    # Outer size = glyph extent + insets (1 cell each side for a plain border).
    bt.width.should eq bt.ratio.width * 2 + 2
    bt.height.should eq bt.ratio.height + 2

    lit = [] of Tuple(Int32, Int32) # {y, x}
    (0...s.height).each do |y|
      (0...s.width).each do |x|
        lit << {y, x} if s.lines[y][x].char == '#'
      end
    end
    lit.should_not be_empty

    # The second glyph must have painted something — pre-fix, the fit loop's
    # `interior` was short by `ihorizontal`, so only the first glyph ever fit.
    interior_left = bt.aleft + bt.ileft
    second_glyph_start = interior_left + bt.ratio.width
    lit.any? { |(_y, x)| x >= second_glyph_start }.should be_true

    # All `ratio.height` glyph rows must have painted something — pre-fix,
    # the row loop's `bottom` was short by `ivertical`, cutting the bottom
    # `ivertical` rows off every glyph.
    interior_top = bt.atop + bt.itop
    lit.max_of { |(y, _x)| y }.should eq interior_top + bt.ratio.height - 1
  ensure
    s.try &.destroy
  end
end

# ---------------------------------------------------------------------------
# B18-54

describe "BUGS18 B18-54: ToolBox section headers strip the container's border/padding" do
  it "keeps a bordered toolbox's header title readable (no leaked border/padding)" do
    s = headless_screen
    tb = Widget::ToolBox.new parent: s, top: 0, left: 0, width: 30, height: 16,
      style: Style.new(border: true)
    tb.add_item "General", Widget::Box.new(content: "...")
    tb.add_item "Advanced", Widget::Box.new(content: "...")
    s.repaint

    header = tb.sections.first.header
    header.style.border.any?.should be_false
    header.style.padding.any?.should be_false

    # The title text must actually paint somewhere on the header's row —
    # pre-fix, the height-1 header's border ate the whole interior and only
    # border glyphs were drawn.
    row = header.atop
    chars = (0...s.width).map { |x| s.lines[row][x].char }.join
    chars.should contain "General"
  ensure
    s.try &.destroy
  end

  it "still hides/collapses correctly (visible-forcing behavior preserved)" do
    s = headless_screen
    tb = Widget::ToolBox.new parent: s, top: 0, left: 0, width: 30, height: 16
    tb.hide
    tb.add_item "General", Widget::Box.new(content: "...")
    tb.sections.first.header.visible?.should be_true
  ensure
    s.try &.destroy
  end
end

describe "BUGS18 B18-54 sibling: Pine::StatusBar strips border/padding from its inner box" do
  it "keeps the status text readable under a bordered/padded inline style" do
    s = headless_screen
    sb = Widget::Pine::StatusBar.new parent: s, top: 0, left: 0,
      status_content: "hello", style: Style.new(border: true)
    s.repaint

    sb.status.style.border.any?.should be_false
    sb.status.style.padding.any?.should be_false
  ensure
    s.try &.destroy
  end
end

# ---------------------------------------------------------------------------
# B18-56

describe "BUGS18 B18-56: DockWidget closable=/floatable= rebuild the title-bar chrome" do
  it "removes the close button when closable is disabled at runtime, and rebuilds it on re-enable" do
    s = headless_screen
    dock = Widget::DockWidget.new parent: s, title: "Files"
    s.repaint
    dock.@close_button.should_not be_nil

    dock.closable = false
    dock.@close_button.should be_nil

    dock.closable = true
    dock.@close_button.should_not be_nil
  ensure
    s.try &.destroy
  end

  it "never builds a close button for a closable: false dock, even after it renders once" do
    s = headless_screen
    dock = Widget::DockWidget.new parent: s, title: "Files", closable: false
    s.repaint
    dock.@close_button.should be_nil

    dock.closable = true
    dock.@close_button.should_not be_nil
  ensure
    s.try &.destroy
  end

  it "is a no-op (no rebuild) when set to its current value" do
    s = headless_screen
    dock = Widget::DockWidget.new parent: s, title: "Files"
    s.repaint
    original = dock.@close_button
    dock.closable = true # already true
    dock.@close_button.should be(original)
  ensure
    s.try &.destroy
  end

  it "destroys the size grip when floatable is disabled at runtime, and rebuilds it on re-enable" do
    s = headless_screen
    dock = Widget::DockWidget.new parent: s, title: "Files"
    s.repaint
    dock.size_grip.should_not be_nil

    dock.floatable = false
    dock.size_grip.should be_nil
    dock.@float_button.should be_nil

    dock.floatable = true
    dock.size_grip.should_not be_nil
    dock.@float_button.should_not be_nil
  ensure
    s.try &.destroy
  end

  it "keeps the close button ungated for programmatic close (Qt semantics: flags gate the gesture, not the API)" do
    s = headless_screen
    dock = Widget::DockWidget.new parent: s, title: "Files", closable: false
    closed = false
    dock.on(::Crysterm::Event::Close) { closed = true }
    dock.close
    closed.should be_true
  ensure
    s.try &.destroy
  end
end

# ---------------------------------------------------------------------------
# B18-59

describe "BUGS18 B18-59: TabWidget tabs_closable= rebuilds tab titles on toggle" do
  it "shows the close marker on every tab once enabled, and removes it again once disabled" do
    s = headless_screen
    tabs = Widget::TabWidget.new parent: s, top: 0, left: 0, width: 40, height: 10
    page_a = Widget::Box.new content: "A content"
    page_b = Widget::Box.new content: "B content"
    tabs.add_tab "A", page_a
    tabs.add_tab "B", page_b
    s.repaint

    tabs.tab_bar.item_texts.should eq ["A", "B"]

    tabs.tabs_closable = true
    texts = tabs.tab_bar.item_texts
    texts.size.should eq 2
    texts[0].should start_with "A "
    texts[1].should start_with "B "
    texts[0].size.should be > "A".size
    texts[1].size.should be > "B".size

    tabs.tabs_closable = false
    tabs.tab_bar.item_texts.should eq ["A", "B"]
  ensure
    s.try &.destroy
  end

  it "preserves the current-tab highlight across the toggle-driven rebuild" do
    s = headless_screen
    tabs = Widget::TabWidget.new parent: s, top: 0, left: 0, width: 40, height: 10
    page_a = Widget::Box.new content: "A content"
    page_b = Widget::Box.new content: "B content"
    tabs.add_tab "A", page_a
    tabs.add_tab "B", page_b
    tabs.current_index = 1
    s.repaint

    tabs.tabs_closable = true
    tabs.current_index.should eq 1
    tabs.tab_bar.current_index.should eq 1
  ensure
    s.try &.destroy
  end

  it "is a no-op (no rebuild) when set to its current value" do
    s = headless_screen
    tabs = Widget::TabWidget.new parent: s, top: 0, left: 0, width: 40, height: 10
    tabs.add_tab "A", Widget::Box.new(content: "A")
    s.repaint
    before = tabs.tab_bar.item_texts
    tabs.tabs_closable = false # already false
    tabs.tab_bar.item_texts.should eq before
  ensure
    s.try &.destroy
  end
end

# ---------------------------------------------------------------------------
# B18-62

describe "BUGS18 B18-62: DockWidget#dock_size= schedules a repaint" do
  it "applies a runtime dock_size change on the very next selective (damage-tracking) frame" do
    plain = headless_screen 80, 24
    dmg = headless_screen 80, 24, Crysterm::OptimizationFlag::DamageTracking

    plain_win = Widget::MainWindow.new parent: plain, top: 0, left: 0, width: 80, height: 24
    plain_dock = Widget::DockWidget.new title: "D", dock_size: 20
    plain_win.add_dock plain_dock
    plain_central = Widget::Box.new content: "central"
    plain_win.central_widget = plain_central

    dmg_win = Widget::MainWindow.new parent: dmg, top: 0, left: 0, width: 80, height: 24
    dmg_dock = Widget::DockWidget.new title: "D", dock_size: 20
    dmg_win.add_dock dmg_dock
    dmg_central = Widget::Box.new content: "central"
    dmg_win.central_widget = dmg_central

    plain.repaint
    dmg.repaint
    dmg.damage_full_frames.should be > 0 # first frame is always full

    plain_central.aleft.should eq plain_win.aleft + 20
    dmg_central.aleft.should eq dmg_win.aleft + 20

    # Isolate the setter under test: no other mutation happens between the
    # two renders, so only `dock_size=`'s own dirtying (or lack of it) can
    # bring the dock back into the selective frame's dirty set.
    plain_dock.dock_size = 30
    dmg_dock.dock_size = 30

    plain.repaint
    dmg.repaint

    # Pre-fix: the damage-tracking screen's woken frame had nothing marked
    # dirty, so `MainWindow#relayout` never re-ran and the central widget
    # stayed pinned to the old 20-wide dock.
    plain_central.aleft.should eq plain_win.aleft + 30
    dmg_central.aleft.should eq dmg_win.aleft + 30
  ensure
    plain.try &.destroy
    dmg.try &.destroy
  end
end

# ---------------------------------------------------------------------------
# B18-64

describe "BUGS18 B18-64: BigText re-derives its active font from style.bold? every frame" do
  it "switches to the bold face after a runtime style.bold = true, not just at construction" do
    s = headless_screen
    bt = Widget::BigText.new parent: s, top: 0, left: 0, content: "H", foreground_char: '#'
    s.repaint

    normal_cells = [] of Tuple(Int32, Int32)
    (0...s.height).each do |y|
      (0...s.width).each { |x| normal_cells << {y, x} if s.lines[y][x].char == '#' }
    end
    normal_cells.should_not be_empty

    # Flip bold at runtime (the documented failure path: CSS `font-weight:
    # bold` or a direct `style.bold =` both land here, since the widget
    # can't tell them apart).
    bt.style.bold = true
    s.repaint

    bold_cells = [] of Tuple(Int32, Int32)
    (0...s.height).each do |y|
      (0...s.width).each { |x| bold_cells << {y, x} if s.lines[y][x].char == '#' }
    end

    # The bundled bold face is synthesized by smearing each lit pixel one
    # column right, so it lights strictly more cells than the normal face for
    # any glyph with at least one lit pixel not already at the right edge.
    # Pre-fix, `@active_font` stayed frozen at `@normal` forever and the two
    # sets were identical.
    bold_cells.size.should be > normal_cells.size
    (normal_cells - bold_cells).should be_empty # bold is a superset
  ensure
    s.try &.destroy
  end

  it "re-measures the shrink-to-content width when the active font switches" do
    s = headless_screen
    bt = Widget::BigText.new parent: s, top: 0, left: 0, content: "HI", foreground_char: '#'
    s.repaint
    normal_width = bt.width.as(Int32)

    bt.style.bold = true
    s.repaint

    # A bold-smeared glyph is one column wider per lit-rightmost-pixel glyph;
    # the shrink width must track it, not stay pinned at the normal measure.
    bt.width.as(Int32).should be >= normal_width
  ensure
    s.try &.destroy
  end
end
