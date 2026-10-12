require "./spec_helper"

include Crysterm

private def row(s, width)
  (s.dump(0, width, 2, 3) || "").lines[2][1..-2]
end

private def field(text, **opts)
  Widget::Label.new **opts, content: text
end

# `StatusBar#add_widget` (Qt's `addWidget`): a *normal* field sits left of
# the permanent ones and gives way to a temporary message, so a bar whose
# fields fill it can still show one.
describe "StatusBar normal fields" do
  it "places a normal field before the permanent ones whatever the add order" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    pos = field "Ln 1", width: 10
    ovr = field "INS", width: 5
    name = field "notes.md"
    bar.add_permanent_widget pos
    bar.add_permanent_widget ovr
    bar.add_widget name
    bar.normal_widgets.should eq [name]
    bar.permanent_widgets.should eq [pos, ovr]
    s.repaint
    name.aleft.should eq 0
    name.awidth.should eq 25
    pos.aleft.should eq 25
    ovr.aleft.should eq 35
    row(s, 40).should start_with "notes.md"
  end

  it "hides the normal fields while a message shows, and brings them back when it clears" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    name = bar.add_widget field("notes.md")
    bar.add_permanent_widget field("Ln 1", width: 10)
    s.repaint
    row(s, 40).should start_with "notes.md"

    bar.show_message "Saved notes.md"
    name.visible?.should be_false
    s.repaint
    line = row s, 40
    line.should start_with "Saved notes.md"
    line[30, 4].should eq "Ln 1" # the permanent field keeps its cells

    bar.clear_message
    name.visible?.should be_true
    s.repaint
    line = row s, 40
    line.should start_with "notes.md"
    line.should_not contain "Saved"
  end

  it "adds a field hidden while a message is up, and shows a removed one again" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    bar.show_message "Busy"
    name = bar.add_widget field("notes.md")
    name.visible?.should be_false
    bar.remove_widget name
    name.visible?.should be_true
    name.parent.should be_nil
    bar.normal_widgets.should be_empty
    bar.add_widget(name).should eq name
    bar.add_widget(name) # a second add is a no-op
    bar.normal_widgets.should eq [name]
  end

  it "brings back only the fields it hid, not one the application hid (QStatusBar::hideOrShow)" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    name = bar.add_widget field("notes.md")
    mode = bar.add_widget field("vi", width: 4)
    mode.hide # the application's own choice
    bar.show_message "Busy"
    name.visible?.should be_false
    mode.visible?.should be_false
    bar.clear_message
    name.visible?.should be_true
    mode.visible?.should be_false
    # A field the bar hid, then removed mid-message, leaves visible; a field
    # the application hid leaves as it was.
    bar.show_message "Busy"
    bar.remove_widget name
    name.visible?.should be_true
    bar.remove_widget mode
    mode.visible?.should be_false
  end

  it "forgets a field destroyed behind its back, and gives the sections its cells" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    bar.add_permanent "UTF-8"
    name = bar.add_widget field("notes.md", width: 10)
    pos = bar.add_permanent_widget field("Ln 1", width: 10)
    bar.show_message "Busy"
    name.destroy
    pos.destroy
    bar.normal_widgets.should be_empty
    bar.permanent_widgets.should be_empty
    bar.clear_message
    s.repaint
    row(s, 40).rstrip.should end_with "UTF-8"
  end

  it "keeps the painted sections left of a visible normal field" do
    s = headless_screen(40, 3)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    bar.add_permanent "UTF-8"
    bar.add_widget field("notes.md", width: 10)
    bar.add_permanent_widget field("Ln 1", width: 10)
    s.repaint
    line = row s, 40
    line[20, 10].should start_with "notes.md"
    line[0, 20].rstrip.should end_with "UTF-8"
  end
end
