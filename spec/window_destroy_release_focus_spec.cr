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
