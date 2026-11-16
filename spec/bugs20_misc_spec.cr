require "./spec_helper"

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "Effect::Animated started where it cannot be seen" do
  it "waits for the hidden ancestor to be shown before ticking" do
    s = headless_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    box.hide
    l = Crysterm::Widget::Loading.new parent: box, top: 0, left: 0, width: 10, height: 1
    l.start
    l.running?.should be_false
    box.show
    l.running?.should be_true
    l.stop
    l.running?.should be_false
  ensure
    s.try &.destroy
  end

  it "stays stopped when stopped before the ancestor is shown" do
    s = headless_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    box.hide
    l = Crysterm::Widget::Loading.new parent: box, top: 0, left: 0, width: 10, height: 1
    l.start
    l.stop
    box.show
    l.running?.should be_false
  ensure
    s.try &.destroy
  end

  it "ends a run paused for visibility on toggle" do
    s = headless_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    box.hide
    l = Crysterm::Widget::Loading.new parent: box, top: 0, left: 0, width: 10, height: 1
    l.start
    l.toggle
    box.show
    l.running?.should be_false
  ensure
    s.try &.destroy
  end
end

describe "Mixin::PercentRange#percent_of" do
  it "stays finite over a range wider than Float64::MAX" do
    s = headless_screen
    g = Crysterm::Widget::Gauge.new parent: s, top: 0, left: 0, width: 20, height: 1,
      minimum: -1e308, maximum: 1e308, value: 1e308
    g.percent_of(1e308).should eq 100.0
    g.percent_of(-1e308).should eq 0.0
    g.percent_of(0.0).should be_close(50.0, 1e-9)
    s.repaint
  ensure
    s.try &.destroy
  end
end

describe "Tput::Unicode.wrap_cut_index" do
  it "keeps one character per row when the width is zero or negative" do
    Tput::Unicode.wrap_cut_index("abcdef", 0, false).should eq 1
    Tput::Unicode.wrap_cut_index("abcdef", -3, false).should eq 1
    Tput::Unicode.wrap_cut_index("abcdef", 0, true).should eq 1
  end

  it "cuts at the column budget otherwise" do
    Tput::Unicode.wrap_cut_index("abcdef", 4, false).should eq 4
    Tput::Unicode.wrap_cut_index("abc", 4, false).should eq 3
  end
end

describe "Crysterm::SGR.params_to_attr" do
  it "ignores bytes that are neither digits nor separators" do
    dfl = Crysterm::Window::DEFAULT_ATTR
    clean = Crysterm::SGR.params_to_attr("1", dfl, dfl)
    Crysterm::SGR.params_to_attr("1 ", dfl, dfl).should eq clean
    Crysterm::SGR.params_to_attr("!!!!!!!!!!!!1", dfl, dfl).should eq clean
  end
end

describe "Application.exec_all" do
  it "returns at once when every listed window is already destroyed" do
    s = headless_screen
    s.destroy
    Crysterm::Application.exec_all [s, s]
  end
end

describe "TerminalEmulator title handler" do
  it "leaves the parser in ground state when the handler raises" do
    dfl = Crysterm::Attr.pack(0, Crysterm::Attr::COLOR_DEFAULT, Crysterm::Attr::COLOR_DEFAULT)
    em = Crysterm::TerminalEmulator.new(10, 2, dfl)
    em.on_title { |_| raise "boom" }
    expect_raises(Exception, "boom") { em.feed "\e]0;t\a" }
    em.feed "ab"
    em.cursor_x.should eq 2
  end
end

describe "ListTable per-cell CSS nodes" do
  it "styles rows added after the first cascade" do
    s = headless_screen
    without_default_theme do
      table = Crysterm::Widget::ListTable.new parent: s, top: 0, left: 0, width: 30, height: 8,
        rows: [["A", "B"], ["1", "2"]]
      s.stylesheet = "Cell { color: red; }"
      s.repaint
      table.css_cell_style(1, 0).not_nil!.fg.should eq rgb("red")
      table.css_cell_style(2, 0).nil?.should be_true

      table.rows = [["A", "B"], ["1", "2"], ["3", "4"]]
      s.repaint
      table.css_cell_style(2, 0).not_nil!.fg.should eq rgb("red")
    end
  ensure
    s.try &.destroy
  end
end

describe "Action#shortcut= with several presenting hosts" do
  it "keeps every host's hold across the change" do
    s = headless_screen
    one = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 1
    two = Crysterm::Widget::Box.new parent: s, top: 2, left: 0, width: 10, height: 1
    a = Crysterm::Action.new "Run", shortcut: Tput::Key::CtrlR
    fired = 0
    a.on(Crysterm::Event::Triggered) { fired += 1 }
    one.add_action a
    two.add_action a
    a.shortcut = Tput::Key::CtrlT

    one.remove_action a
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlT)
    fired.should eq 1

    two.remove_action a
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlT)
    fired.should eq 1
  ensure
    s.try &.destroy
  end
end

describe "SGR-Pixels requested before the cell size is known" do
  it "takes effect once the device learns its cell size" do
    buf = IO::Memory.new
    s = Crysterm::Window.new(input: IO::Memory.new, output: buf, error: IO::Memory.new)
    s.screen.cell_pixel_width = 0
    s.screen.cell_pixel_height = 0
    s.enable_mouse(pixels: :on)
    s.tput.mouse_cell_pixels.should be_nil

    s.screen.spec_apply_cell_pixels 8, 16
    s.tput.mouse_cell_pixels.should eq({8, 16})
  ensure
    s.try &.destroy
    spec_reset_cell_geometry_anchor
  end

  it "re-sends nothing on a cell size change when pixels were not asked for" do
    buf = IO::Memory.new
    s = Crysterm::Window.new(input: IO::Memory.new, output: buf, error: IO::Memory.new)
    s.enable_mouse
    s.tput.flush
    buf.clear

    s.screen.spec_apply_cell_pixels 8, 16
    s.tput.flush
    buf.to_s.should eq ""
  ensure
    s.try &.destroy
    spec_reset_cell_geometry_anchor
  end
end

describe "Widget#destroy with a raising Destroy handler" do
  it "still runs the later Destroy handlers and drops them all" do
    s = headless_screen
    box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 1
    later = 0
    box.on(Crysterm::Event::Destroy) { raise "boom" }
    box.on(Crysterm::Event::Destroy) { later += 1 }
    expect_raises(Exception, "boom") { box.destroy }
    later.should eq 1
    box.window?.nil?.should be_true
  ensure
    s.try &.destroy
  end
end

describe "MenuBar Alt mnemonics" do
  it "opens a menu on an Alt+digit chord delivered with an ESC prefix" do
    s = headless_screen
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    bar.add_menu "&1 One"
    bar.add_menu "&2 Two"
    s.repaint
    ke = Tput::KeyEvent.from_esc_prefixed('2').not_nil!
    s.emit Crysterm::Event::KeyPress.new('\e', nil, nil, ke)
    bar.open_index.should eq 1
  ensure
    s.try &.destroy
  end
end
