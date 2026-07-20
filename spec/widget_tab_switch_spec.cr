require "./spec_helper"

include Crysterm

private def tab_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 60, height: 16)
end

private def screen_text(s) : String
  String.build do |io|
    s.lines.each do |line|
      (0...s.awidth).each do |x|
        c = line[x]?.try(&.char) || ' '
        io << (c == '\0' ? ' ' : c)
      end
      io << '\n'
    end
  end
end

describe "TabWidget switching (regression check)" do
  it "renders a switched-to page's content" do
    s = tab_screen
    tw = Widget::TabWidget.new parent: s, top: 0, left: 0, width: "100%", height: "100%",
      style: Style.new(border: true)

    p0 = Widget::Box.new
    p1 = Widget::Box.new
    tw.add_tab "Apage", p0
    tw.add_tab "Bpage", p1
    Widget::Box.new parent: p0, top: 1, left: 1, width: 7, height: 1, content: "AAAcc"
    Widget::Box.new parent: p1, top: 1, left: 1, width: 7, height: 1, content: "BBBcc"

    s.repaint
    t0 = screen_text s
    (t0.includes?("AAAcc")).should be_true  # tab 0 content renders
    (t0.includes?("BBBcc")).should be_false # tab 1 hidden

    tw.current_index = 1
    s.repaint
    t1 = screen_text s
    (t1.includes?("BBBcc")).should be_true # <-- switched-to page must render
    (t1.includes?("AAAcc")).should be_false
  end

  it "renders a switched-to page immediately when a ::pane rule is active" do
    # A `TabWidget::pane` rule makes `sync_tab_style` push the pane sub-style onto
    # the current page. Bug: the shared pane object was assigned directly, so
    # hiding the old page flipped the shared object's `visible` to false and the
    # freshly-raised page rendered blank for a frame. Each page must get its own copy.
    s = tab_screen
    s.stylesheet = "TabWidget::pane { background-color: #202020; }"
    tw = Widget::TabWidget.new parent: s, top: 0, left: 0, width: "100%", height: "100%",
      style: Style.new(border: true)
    p0 = Widget::Box.new
    p1 = Widget::Box.new
    tw.add_tab "Apage", p0
    tw.add_tab "Bpage", p1
    Widget::Box.new parent: p0, top: 1, left: 1, width: 7, height: 1, content: "AAAcc"
    Widget::Box.new parent: p1, top: 1, left: 1, width: 7, height: 1, content: "BBBcc"

    s.repaint
    tw.current_index = 1
    s.repaint
    # No intervening toggle: the very first render after the switch must show it.
    screen_text(s).includes?("BBBcc").should be_true
    p1.style.visible?.should be_true # visibility preserved through the pane push
  end
end

# Minimal includer to lock the `Mixin::PagedContainer` contract directly: real
# widgets never expose `current_index == -1` with pages present, but the mixin
# promises `current_widget == nil` when no page is selected.
private class FakePaged
  include Crysterm::Mixin::PagedContainer
end

describe Crysterm::Mixin::PagedContainer do
  it "current_widget is nil while no page is selected, even with pages present" do
    f = FakePaged.new
    f.current_widget.should be_nil # empty
    f.pages << Widget::Box.new
    f.pages << Widget::Box.new
    # -1 sentinel; must not negative-index to the last page.
    f.current_index.should eq -1
    f.current_widget.should be_nil
  end
end
