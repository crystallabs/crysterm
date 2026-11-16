require "./spec_helper"

include Crysterm

private def fu_window(width = 20, height = 4)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
  s.full_unicode = true
  s
end

# Stamps `text` on its first interior row through `Box`'s text-run helpers.
private class StampProbe < Crysterm::Widget::Box
  property text = ""
  property? centered = false

  def paint(*, with_children = true)
    with_inner_coords(with_children) do |xi, xl, yi, _yl|
      if centered?
        draw_centered_text yi, xi, xl, @text
      else
        draw_text_run yi, xi, @text, xl
      end
    end
  end
end

describe "Widget#coords for a grandchild of a scrolled container" do
  it "shifts the grandchild by the scroll offset once" do
    s = headless_screen(40, 12)
    outer = Widget.new parent: s, top: 0, left: 0, width: 20, height: 6,
      scrollable: true
    Widget.new parent: outer, top: 30, left: 0, width: 5, height: 1
    mid = Widget.new parent: outer, top: 5, left: 0, width: 10, height: 4
    g = Widget.new parent: mid, top: 1, left: 0, width: 5, height: 1
    s.repaint

    outer.scroll_to 3, always: true
    s.repaint

    outer.child_base.should eq 3
    mid.lpos.not_nil!.yi.should eq 2
    g.lpos.not_nil!.yi.should eq 3
  end
end

describe "Widget#coords under a parent clipped by a scrolled ancestor" do
  it "anchors a grandchild on the parent's true top edge, not the clamped one" do
    s = headless_screen(40, 12)
    outer = Widget.new parent: s, top: 0, left: 0, width: 20, height: 6,
      scrollable: true
    Widget.new parent: outer, top: 30, left: 0, width: 5, height: 1
    mid = Widget.new parent: outer, top: 5, left: 0, width: 10, height: 4
    g = Widget.new parent: mid, top: 1, left: 0, width: 5, height: 1
    low = Widget.new parent: mid, bottom: 0, left: 0, width: 5, height: 1
    s.repaint

    outer.scroll_to 6, always: true
    s.repaint

    mid.lpos.not_nil!.yi.should eq 0
    mid.lpos.not_nil!.yl.should eq 3
    g.lpos.not_nil!.yi.should eq 0
    low.lpos.not_nil!.yi.should eq 2
  end

  it "places the children of a top-clipped bordered scrollable below its hidden border row" do
    s = headless_screen(40, 12)
    outer = Widget.new parent: s, top: 0, left: 0, width: 20, height: 8,
      scrollable: true
    Widget.new parent: outer, top: 30, left: 0, width: 5, height: 1
    pane = Widget.new parent: outer, top: 2, left: 0, width: 10, height: 5,
      scrollable: true, style: Style.new(border: true)
    g = Widget.new parent: pane, top: 0, left: 0, width: 5, height: 1
    s.repaint
    g.lpos.not_nil!.yi.should eq 3

    outer.scroll_to 3, always: true
    s.repaint

    pane.lpos.not_nil!.yi.should eq 0
    g.lpos.not_nil!.yi.should eq 0
  end

  it "keeps a shrink-to-fit parent's size while scrolled" do
    s = headless_screen(40, 12)
    outer = Widget.new parent: s, top: 0, left: 0, width: 20, height: 6,
      scrollable: true
    Widget.new parent: outer, top: 30, left: 0, width: 5, height: 1
    fit = Widget.new parent: outer, top: 5, left: 0, shrink_to_fit: true
    g = Widget.new parent: fit, top: 0, left: 0, width: 5, height: 3
    s.repaint

    outer.scroll_to 4, always: true
    s.repaint

    fit.lpos.not_nil!.yi.should eq 1
    fit.lpos.not_nil!.yl.should eq 4
    g.lpos.not_nil!.yi.should eq 1
    g.lpos.not_nil!.yl.should eq 4
  end
end

describe "Box text-run stamping" do
  it "gives a wide glyph a lead cell and a continuation cell (full_unicode)" do
    s = fu_window
    pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
    StampProbe.new(parent: s, top: 0, left: 0, width: 10, height: 1).text = "中a"
    s.repaint

    row = s.cell_rows[0]
    row[0].char.should eq '中'
    row[1].continuation?.should be_true
    row[2].char.should eq 'a'
  end

  it "centers by display width (full_unicode)" do
    s = fu_window
    pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
    w = StampProbe.new parent: s, top: 0, left: 0, width: 10, height: 1
    w.centered = true
    w.text = "中文"
    s.repaint

    row = s.cell_rows[0]
    row[3].char.should eq '中'
    row[4].continuation?.should be_true
    row[5].char.should eq '文'
    row[6].continuation?.should be_true
  end

  it "blanks a wide glyph cut by the clip edge (full_unicode)" do
    s = fu_window
    pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
    StampProbe.new(parent: s, top: 0, left: 0, width: 2, height: 1).text = "a中"
    s.repaint

    row = s.cell_rows[0]
    row[0].char.should eq 'a'
    row[1].char.should eq ' '
    row[2].continuation?.should be_false
  end

  it "merges a combining mark into the preceding glyph (full_unicode)" do
    s = fu_window
    pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
    StampProbe.new(parent: s, top: 0, left: 0, width: 10, height: 1).text = "e\u{301}x"
    s.repaint

    row = s.cell_rows[0]
    row[0].grapheme.should eq "e\u{301}"
    row[1].char.should eq 'x'
  end

  it "keeps one codepoint per cell without full_unicode" do
    s = headless_screen(20, 4)
    s.full_unicode = false
    StampProbe.new(parent: s, top: 0, left: 0, width: 10, height: 1).text = "中a"
    s.repaint

    row = s.cell_rows[0]
    row[0].char.should eq '中'
    row[1].char.should eq 'a'
  end
end

describe "Widget#inline_style= under an active stylesheet" do
  it "recomputes a css-styled widget's style" do
    s = headless_screen(40, 10)
    without_default_theme do
      w = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
      s.stylesheet = "Box { background-color: #112233; }"
      s.repaint
      w.css_styled?.should be_true

      w.inline_style = Style.new(fg: 0x445566)
      s.repaint
      w.style.fg.should eq 0x445566

      w.inline_style = nil
      s.repaint
      w.style.fg.should_not eq 0x445566
    end
  end

  it "does not recascade on every frame for a css-styled label" do
    s = headless_screen(40, 10)
    without_default_theme do
      w = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 4
      w.label = "title"
      s.stylesheet = "Box { background-color: #112233; } Box::label { color: #445566; }"
      3.times { s.repaint }
      before = s.css_cascades_serialized
      3.times { s.repaint }
      s.css_cascades_serialized.should eq before
    end
  end
end

describe "CSS structural invalidation" do
  it "styles a scroll bar enabled after the first cascade" do
    s = headless_screen(40, 10)
    without_default_theme do
      box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3,
        scrollable: true, scrollbar_policy: :always_off
      s.stylesheet = "Box::scrollbar { color: red; }"
      s.repaint
      box.styles.normal.scrollbar.fg.should be_nil

      box.scrollbar_policy = :as_needed
      s.repaint
      box.styles.normal.scrollbar.fg.should eq rgb("red")
    end
  end

  it "styles table rows added after the first cascade and forgets removed ones" do
    s = headless_screen(80, 24)
    without_default_theme do
      table = Widget::Table.new parent: s, rows: [["A", "B"], ["1", "2"]]
      s.stylesheet = "Row:nth-child(3) Cell { color: red; }"
      s.repaint
      table.css_cell_style(2, 0).should be_nil

      table.rows = [["A", "B"], ["1", "2"], ["3", "4"]]
      s.repaint
      table.css_cell_style(2, 0).not_nil!.fg.should eq rgb("red")

      table.rows = [["A", "B"]]
      s.repaint
      table.css_cell_style(2, 0).should be_nil
    end
  end
end

describe "Action accelerators shared by several hosts" do
  it "stay live until the last presenting host withdraws" do
    s = headless_screen(80, 24)
    tb = Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    other = Widget::Box.new parent: s, top: 2, left: 0, width: 10, height: 1
    a = Action.new "Run", shortcut: Tput::Key::CtrlR
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    tb.add_action a
    other.add_action a

    tb.destroy
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlR)
    fired.should eq 1

    other.destroy
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlR)
    fired.should eq 1
  end

  it "go live for a host-less install made before the shortcut was set" do
    s = headless_screen(80, 24)
    a = Action.new "Run"
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    a.install_shortcut s
    a.shortcut = Tput::Key::CtrlR

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlR)
    fired.should eq 1

    a.uninstall_shortcut s
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlR)
    fired.should eq 1
  end
end

describe "ToolButton click with a menu that is visible but not popped up" do
  it "opens the menu, and closes it on the next click" do
    s = headless_screen(80, 24)
    m = Widget::Menu.new parent: s, width: 12, height: 3
    m.add_action "Rename"
    tb = Widget::ToolButton.new parent: s, top: 3, left: 10, width: 12, height: 1, menu: m
    shown = 0
    hidden = 0
    m.on(Event::AboutToShow) { shown += 1 }
    m.on(Event::AboutToHide) { hidden += 1 }
    s.repaint

    tb.handle_click nil
    shown.should eq 1
    hidden.should eq 0

    tb.handle_click nil
    shown.should eq 1
    hidden.should eq 1
    m.visible?.should be_false
  end
end
