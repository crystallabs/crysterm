require "./spec_helper"

include Crysterm

private def cf_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w, height: h,
    default_quit_keys: false)
end

private def cf_mouse_down(x : Int32, y : Int32)
  Crysterm::Event::Mouse.new(
    Tput::Mouse::Event.new(Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, x, y))
end

# BUGS16 B16-42: GroupBox's checkable title-row click hit-tested layout coords
# (`atop`/`aleft`), not the painted rect (`@lpos`) that dispatch actually
# hit-tests. Inside a scrolled ancestor the painted rect is shifted by the
# ancestor's scroll base, so the visible title row no longer lines up with
# `atop`, and a body row scrolled up to `atop` would wrongly toggle instead.
describe "BUGS16 B16-42: GroupBox checkable toggle hit-tests the painted rect" do
  it "toggles on the visible (painted) title row, not the stale layout row" do
    s = cf_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 6,
      scrollable: true
    gb = Widget::GroupBox.new parent: box, title: "Opt", checkable: true,
      top: 8, left: 2, width: 20, height: 6
    # A child far below gives the scrollable box a real scroll extent.
    Widget::Box.new parent: box, top: 30, left: 0, width: 4, height: 1
    s.repaint

    box.scroll_to 4, true
    s.repaint

    lp = gb.lpos.not_nil!
    lp.yi.should_not eq gb.atop
    lp.yi.should eq gb.atop - 4 # painted 4 rows above the layout position

    # Clicking the stale layout row (where the title used to sit before
    # scrolling) must NOT toggle: nothing is painted there anymore.
    gb.emit Crysterm::Event::Mouse, cf_mouse_down(gb.aleft + 1, gb.atop).mouse
    gb.checked?.should be_true

    # Clicking the visible (painted) title row toggles.
    gb.emit Crysterm::Event::Mouse, cf_mouse_down(gb.aleft + 1, lp.yi).mouse
    gb.checked?.should be_false
  end

  it "keeps unscrolled placement toggling exactly as before (no regression)" do
    s = cf_screen
    gb = Widget::GroupBox.new parent: s, title: "Opt", checkable: true,
      top: 0, left: 0, width: 30, height: 8
    s.repaint
    gb.checked?.should be_true

    gb.emit Crysterm::Event::Mouse, cf_mouse_down(gb.aleft + 1, gb.atop).mouse
    gb.checked?.should be_false
  end

  it "does not toggle when the title row itself is scrolled out of view" do
    s = cf_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 6,
      scrollable: true
    gb = Widget::GroupBox.new parent: box, title: "Opt", checkable: true,
      top: 0, left: 2, width: 20, height: 6
    Widget::Box.new parent: box, top: 30, left: 0, width: 4, height: 1
    s.repaint

    # Scroll far enough that the group's title row (top of the group) is
    # above the viewport; only body rows remain visible.
    box.scroll_to 4, true
    s.repaint

    lp = gb.lpos.not_nil!
    lp.no_top?.should be_true # title clipped off, not just shifted

    # The first visible row now sits at the viewport top (box.atop), which is
    # a BODY row, not the title. It must not toggle.
    gb.emit Crysterm::Event::Mouse, cf_mouse_down(gb.aleft + 1, box.atop).mouse
    gb.checked?.should be_true
  end
end

# BUGS16 B16-43: MainWindow#relayout reserved rows for the menu bar / status
# bar merely because the slot was present, unlike tool bars and docks which
# check `#visible?`. Hiding a bar left a permanent blank strip.
describe "BUGS16 B16-43: MainWindow#relayout skips hidden menu/status bars" do
  it "reclaims the top row for the central widget when the menu bar is hidden" do
    s = cf_screen
    win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: 80, height: 24
    win.menu_bar.hide
    central = Widget::Box.new content: "central"
    win.central_widget = central
    s.repaint

    central.atop.should eq win.atop # no blank strip reserved for the hidden menu bar
  end

  it "reclaims the bottom row for the central widget when the status bar is hidden" do
    s = cf_screen
    win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: 80, height: 24
    win.status_bar.hide
    central = Widget::Box.new content: "central"
    win.central_widget = central
    s.repaint

    central.atop.should eq win.atop
    central.aheight.should eq win.aheight # spans the full height, no bottom strip
  end

  it "still reserves rows for a menu/status bar that stays visible (no regression)" do
    s = cf_screen
    win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: 80, height: 24
    win.menu_bar # constructs it, left visible
    win.status_bar
    central = Widget::Box.new content: "central"
    win.central_widget = central
    s.repaint

    central.atop.should eq win.atop + 1
    central.aheight.should eq win.aheight - 2
  end

  it "restores the reserved row when a hidden bar is shown again" do
    s = cf_screen
    win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: 80, height: 24
    win.menu_bar.hide
    central = Widget::Box.new content: "central"
    win.central_widget = central
    s.repaint
    central.atop.should eq win.atop

    win.menu_bar.show
    s.repaint
    central.atop.should eq win.atop + 1
  end
end

# BUGS16 B16-44: ProgressBar#on_keypress stepped the value on its handled keys
# but never called `e.accept`, so the same keystroke also bubbled to and
# double-acted on an ancestor handler.
describe "BUGS16 B16-44: ProgressBar#on_keypress accepts its handled keys" do
  it "accepts Left/Down/'h'/'j' after stepping down" do
    pb = Widget::ProgressBar.new value: 50, minimum: 0, maximum: 100, single_step: 5

    e = Crysterm::Event::KeyPress.new '\0', Tput::Key::Left
    pb.on_keypress e
    pb.value.should eq 45
    e.accepted?.should be_true

    e = Crysterm::Event::KeyPress.new 'j'
    pb.on_keypress e
    pb.value.should eq 40
    e.accepted?.should be_true
  end

  it "accepts Right/Up/'l'/'k' after stepping up" do
    pb = Widget::ProgressBar.new value: 50, minimum: 0, maximum: 100, single_step: 5

    e = Crysterm::Event::KeyPress.new '\0', Tput::Key::Right
    pb.on_keypress e
    pb.value.should eq 55
    e.accepted?.should be_true

    e = Crysterm::Event::KeyPress.new 'k'
    pb.on_keypress e
    pb.value.should eq 60
    e.accepted?.should be_true
  end

  it "accepts a handled key even when already at the bound (clamped no-op)" do
    pb = Widget::ProgressBar.new value: 0, minimum: 0, maximum: 100, single_step: 5

    e = Crysterm::Event::KeyPress.new 'h' # already at minimum: value doesn't move
    pb.on_keypress e
    pb.value.should eq 0
    e.accepted?.should be_true
  end

  it "leaves an unrelated key unaccepted" do
    pb = Widget::ProgressBar.new value: 50, minimum: 0, maximum: 100, single_step: 5

    e = Crysterm::Event::KeyPress.new 'x'
    pb.on_keypress e
    pb.value.should eq 50
    e.accepted?.should be_false
  end

  it "does not double-act on an ancestor's bubbled-key handler" do
    s = cf_screen
    pb = Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 20, height: 1,
      value: 50, minimum: 0, maximum: 100, single_step: 5
    pb.focus
    ancestor_hits = 0
    s.on(Crysterm::Event::KeyPress) { |e| ancestor_hits += 1 unless e.accepted? }
    s.repaint

    s.emit Crysterm::Event::KeyPress.new 'j'

    pb.value.should eq 45
    ancestor_hits.should eq 0 # the bar accepted it: no ancestor double-act
  end
end
