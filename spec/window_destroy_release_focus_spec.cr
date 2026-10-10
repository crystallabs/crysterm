require "./spec_helper"

include Crysterm

# `Window#destroy` releases keyboard focus before tearing its widgets down.
# Without that, destroying the focused widget rewound focus to the next
# surviving widget and emitted `Event::FocusIn` there while its siblings were
# half gone: a handler reading another widget's geometry (a status bar
# refresh asking a pane for its size) raised on the one just detached.
describe "Window#destroy focus release" do
  it "emits no FocusIn during teardown, and blurs the focused widget once" do
    s = headless_screen(40, 10)
    row = Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: "100%"
    layout = Layout::HBox.new
    row.layout = layout
    a = Widget::Box.new input: true
    b = Widget::Box.new input: true
    c = Widget::Box.new input: true
    layout.add_widget a
    layout.add_widget b
    layout.add_widget c
    s.repaint
    # Focus history: c under b, so detaching b would rewind to c.
    s.focus c
    s.focus b
    s.focused.should eq b

    focus_ins = 0
    heights = [] of Int32
    c.on(Event::FocusIn) do
      focus_ins += 1
      heights << b.aheight # the handler the rewind used to crash in
    end
    blurred = [] of Widget?
    b.on(Event::FocusOut) { |e| blurred << e.next_focused }

    s.destroy

    focus_ins.should eq 0
    blurred.should eq [nil]
    s.focused.should be_nil
  end

  it "release_focus blurs and forgets the history, so a rewind has nothing to restore" do
    s = headless_screen(20, 5)
    a = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 2, input: true
    b = Widget::Box.new parent: s, top: 2, left: 0, width: 10, height: 2, input: true
    s.focus a
    s.focus b
    s.release_focus
    s.focused.should be_nil
    b.state.focused?.should be_false
    s.rewind_focus.should be_nil
    s.focused.should be_nil
  ensure
    s.try &.destroy
  end
end

# `Widget#destroy` gives focus up the way Qt's `~QWidget` does (`clearFocus`):
# a `FocusOut` with no successor, nothing focused afterwards, no `FocusIn` to
# the previously focused widget. A hide or a plain detach still rewinds.
describe "Widget#destroy focus release" do
  it "blurs the destroyed widget without handing focus on" do
    s = headless_screen(20, 5)
    a = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 2, input: true
    b = Widget::Box.new parent: s, top: 2, left: 0, width: 10, height: 2, input: true
    s.focus a
    s.focus b
    a_in = 0
    a.on(Event::FocusIn) { a_in += 1 }
    blurred = [] of Widget?
    b.on(Event::FocusOut) { |e| blurred << e.next_focused }
    b.destroy
    blurred.should eq [nil]
    a_in.should eq 0
    s.focused.should be_nil
    a.focused?.should be_false
    # Focus can still be given explicitly afterwards.
    s.focus a
    s.focused.should eq a
  ensure
    s.try &.destroy
  end

  it "forgets a destroyed widget deeper in the history, so a later rewind skips it" do
    s = headless_screen(20, 5)
    a = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 1, input: true
    b = Widget::Box.new parent: s, top: 1, left: 0, width: 10, height: 1, input: true
    c = Widget::Box.new parent: s, top: 2, left: 0, width: 10, height: 1, input: true
    s.focus a
    s.focus b
    s.focus c
    b.destroy # not focused: nothing to blur, c keeps focus
    s.focused.should eq c
    c.hide # a hide still rewinds, past the destroyed b to a
    s.focused.should eq a
    a.destroy # focused: nothing is focused afterwards, as in Qt
    s.focused.should be_nil
  ensure
    s.try &.destroy
  end

  it "still rewinds focus on a hide or a detach" do
    s = headless_screen(20, 5)
    a = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 2, input: true
    b = Widget::Box.new parent: s, top: 2, left: 0, width: 10, height: 2, input: true
    s.focus a
    s.focus b
    b.hide
    s.focused.should eq a
    b.show
    s.focus b
    s.remove b
    s.focused.should eq a
  ensure
    s.try &.destroy
  end
end
