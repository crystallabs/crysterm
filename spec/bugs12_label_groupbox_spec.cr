require "./spec_helper"

include Crysterm

# BUGS12 #8, #24 (widget_label.cr) and #32 (widget/group_box.cr).

private def label_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 20, height: 10)
end

# BUGS12 #8 — `remove_label` passed the nilable Scroll/Resize wrapper ivars
# straight to `off`. The event_handler shard has no `off` overload for `Nil`,
# so a nil wrapper fell through to the catch-all `off(type)` =
# `remove_all_handlers`, wiping EVERY Scroll and Resize handler on the widget.
# The wrappers are nil whenever `@_label` was set without going through
# `set_label` (e.g. assigning `_label` directly).
describe "BUGS12 8: remove_label keeps unrelated Scroll/Resize handlers" do
  it "does not wipe the widget's handlers when the label wrappers are nil" do
    s = label_screen
    box = Widget::Box.new parent: s, width: 10, height: 5

    # Assign the label directly: `@ev_label_scroll`/`@ev_label_resize` stay nil.
    box._label = Widget::Box.new parent: box, content: "x"

    scrolled = 0
    box.on(Crysterm::Event::Scroll) { scrolled += 1 }
    box.on(Crysterm::Event::Resize) { }

    scroll_before = box.handlers(Crysterm::Event::Scroll).size
    resize_before = box.handlers(Crysterm::Event::Resize).size
    scroll_before.should be > 0

    box.remove_label

    # The unrelated handlers must survive — the buggy nil dispatch removed all.
    box.handlers(Crysterm::Event::Scroll).size.should eq scroll_before
    box.handlers(Crysterm::Event::Resize).size.should eq resize_before
    box._label.should be_nil

    # And the surviving Scroll handler still fires.
    box.emit Crysterm::Event::Scroll.new
    scrolled.should eq 1
  end

  it "still detaches the wrappers when set_label created them" do
    s = label_screen
    box = Widget::Box.new parent: s, width: 10, height: 5
    box.set_label "Title"

    scroll_with_label = box.handlers(Crysterm::Event::Scroll).size
    resize_with_label = box.handlers(Crysterm::Event::Resize).size

    box.remove_label

    # The label's own Scroll/Resize wrappers are gone (one fewer each).
    box.handlers(Crysterm::Event::Scroll).size.should eq scroll_with_label - 1
    box.handlers(Crysterm::Event::Resize).size.should eq resize_with_label - 1
    box._label.should be_nil
  end
end

# BUGS12 #24 — `place_label_side` bakes the construction-time inset
# (`2 - ileft` / `2 - iright`) into the label position. `sync_label_position`
# re-glued only the TOP for a border that cascaded in after construction, so
# the title stayed one cell off horizontally. It must also re-run
# `place_label_side` when the horizontal inset drifts.
describe "BUGS12 24: sync_label_position re-glues the label's horizontal inset" do
  it "re-glues a left label when a border cascades in after construction" do
    s = label_screen
    box = Widget::Box.new parent: s, width: 10, height: 5
    box.set_label "Title" # side defaults to "left"
    lbl = box._label.not_nil!

    box.ileft.should eq 0
    lbl.left.should eq 2 # 2 - ileft, ileft == 0

    # Border lands after construction (a stylesheet border on GroupBox, etc.).
    box.style.border = true
    box.invalidate_frame_style
    box.ileft.should eq 1

    box.sync_label_position

    # Was one cell off (still 2) before the fix; now compensates: 2 - ileft.
    lbl.left.should eq 1
  end

  it "re-glues a right label too" do
    s = label_screen
    box = Widget::Box.new parent: s, width: 10, height: 5
    box.set_label "T", side: "right"
    lbl = box._label.not_nil!

    lbl.right.should eq 2 # 2 - iright, iright == 0

    box.style.border = true
    box.invalidate_frame_style
    box.iright.should eq 1

    box.sync_label_position

    lbl.right.should eq 1 # 2 - iright
  end

  it "leaves the label untouched when the inset has not moved" do
    s = label_screen
    box = Widget::Box.new parent: s, width: 10, height: 5
    box.set_label "Title"
    lbl = box._label.not_nil!

    before = lbl.left
    box.sync_label_position
    lbl.left.should eq before
  end
end

# BUGS12 #32 — `GroupBox#update_label` skipped instead of clearing when the
# "nothing to show" state (empty title, not checkable) was reached at runtime,
# leaving a stale border label after `title = ""` or `checkable = false`.
describe "BUGS12 32: GroupBox#update_label clears the stale label" do
  it "removes the label when the title is cleared" do
    s = label_screen
    gb = Widget::GroupBox.new parent: s, title: "Options", width: 20, height: 6
    gb._label.should_not be_nil

    gb.title = ""
    gb._label.should be_nil
  end

  it "removes the label when checkability is turned off on an empty title" do
    s = label_screen
    gb = Widget::GroupBox.new parent: s, title: "", checkable: true, width: 20, height: 6
    gb._label.should_not be_nil # the [x] marker keeps a label

    gb.checkable = false
    gb._label.should be_nil
  end

  it "still shows a label when there is something to show" do
    s = label_screen
    gb = Widget::GroupBox.new parent: s, title: "Keep", width: 20, height: 6
    gb.title = "Renamed"
    gb._label.should_not be_nil
    gb._label.not_nil!.content.should contain "Renamed"
  end
end
