require "./spec_helper"

include Crysterm

private def tab_screen
  Crysterm::Screen.new(
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

    s._render
    t0 = screen_text s
    (t0.includes?("AAAcc")).should be_true  # tab 0 content renders
    (t0.includes?("BBBcc")).should be_false # tab 1 hidden

    tw.show_tab 1
    s._render
    t1 = screen_text s
    (t1.includes?("BBBcc")).should be_true  # <-- switched-to page must render
    (t1.includes?("AAAcc")).should be_false
  end
end
