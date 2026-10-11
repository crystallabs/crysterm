require "./spec_helper"

include Crysterm

# `Widget#toggle_view_action`: Qt's `toggleViewAction` for any widget — a
# checkable action that shows and hides it, checked while it is visible.

private def pane(s)
  Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 2
end

describe "Widget#toggle_view_action" do
  it "is one checkable action per widget, checked while the widget is visible" do
    s = headless_screen(40, 8)
    w = pane s
    a = w.toggle_view_action "&Pane"
    a.text.should eq "&Pane"
    a.checkable?.should be_true
    a.checked?.should be_true
    w.toggle_view_action("other").should be a
    a.text.should eq "&Pane"
    s.destroy
  end

  it "hides and shows the widget when triggered" do
    s = headless_screen(40, 8)
    w = pane s
    a = w.toggle_view_action "Pane"
    a.trigger
    w.visible?.should be_false
    a.checked?.should be_false
    a.trigger
    w.visible?.should be_true
    a.checked?.should be_true
    s.destroy
  end

  it "follows a show or hide from anywhere else" do
    s = headless_screen(40, 8)
    w = pane s
    a = w.toggle_view_action "Pane"
    w.hide
    a.checked?.should be_false
    w.show
    a.checked?.should be_true
    s.destroy
  end

  it "takes the widget's label as its text by default" do
    s = headless_screen(40, 8)
    w = pane s
    w.label = "Files"
    w.toggle_view_action.text.should eq "Files"
    s.destroy
  end

  it "does nothing while disabled, the check staying with the widget" do
    s = headless_screen(40, 8)
    w = pane s
    a = w.toggle_view_action "Pane"
    a.enabled = false
    a.trigger
    w.visible?.should be_true
    a.checked?.should be_true
    s.destroy
  end
end
