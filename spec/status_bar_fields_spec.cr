require "./spec_helper"

include Crysterm

private def row(s, width)
  (s.dump(0, width, 2, 3) || "").lines[2][1..-2]
end

# `StatusBar#add_permanent_widget` (Qt's `addPermanentWidget`): the bar hosts
# widgets as fields in a `Layout::HBox`, sized by their own width specs.
describe "StatusBar fields" do
  it "lays the fields out in one row, percentages dividing the bar, the rest to the unsized field" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    name = Widget::Label.new content: "notes.md"
    pos = Widget::Label.new width: "25%", content: "Ln 1"
    ovr = Widget::ToolButton.new width: 5, text: "INS"
    bar.add_permanent_widget name
    bar.add_permanent_widget pos
    bar.add_permanent_widget ovr
    bar.permanent_widgets.should eq [name, pos, ovr]
    s.repaint
    name.awidth.should eq 25 # 40 - 10 - 5
    pos.awidth.should eq 10
    ovr.awidth.should eq 5
    name.aleft.should eq 0
    pos.aleft.should eq 25
    ovr.aleft.should eq 35
    line = row s, 40
    line.should start_with "notes.md"
    line[25, 4].should eq "Ln 1"
    line.should contain "INS"
  end

  it "keeps the painted sections left of the fields" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    bar.layout = Layout::HBox.new justify: Layout::Box::Justify::End
    bar.add_permanent "Ln 1"
    bar.add_permanent_widget Widget::ToolButton.new(width: 5, text: "INS")
    s.repaint
    line = row s, 40
    line[35, 5].should contain "INS"
    line[0, 35].rstrip.should end_with "Ln 1"
    line[34].should eq ' '
  end

  it "fires a field button's click from a mouse press on it" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    bar.add_permanent_widget Widget::Label.new(content: "x")
    ovr = Widget::ToolButton.new width: 5, text: "INS"
    bar.add_permanent_widget ovr
    clicks = 0
    ovr.on_clicked { clicks += 1 }
    s.repaint
    x = ovr.aleft + 1
    s.dispatch_mouse Tput::Mouse::Event.new(Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, x, 2)
    s.dispatch_mouse Tput::Mouse::Event.new(Tput::Mouse::Action::Up, Tput::Mouse::Button::Left, x, 2)
    clicks.should eq 1
  end

  it "removes a field and releases its cells" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    a = Widget::Label.new content: "aaa"
    b = Widget::Label.new width: 10, content: "bbb"
    bar.add_permanent_widget a
    bar.add_permanent_widget b
    s.repaint
    a.awidth.should eq 30
    bar.remove_permanent_widget b
    s.repaint
    a.awidth.should eq 40
    bar.permanent_widgets.should eq [a]
  end
end
