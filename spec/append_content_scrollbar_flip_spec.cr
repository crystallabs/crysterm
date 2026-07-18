require "./spec_helper"

include Crysterm

# `Widget#append_content` fast path wraps only the appended segment, using the
# *current* `content_margin_x`. If the append crosses the overflow threshold and
# an `AsNeeded` vertical scrollbar appears, `content_margin_x` grows by
# `scrollbar_width` and a full reparse would re-wrap *every* line at the narrower
# width. The fast path must not silently leave the pre-flip wrapping in place.
describe "Widget#append_content across an AsNeeded scrollbar flip" do
  it "matches a full reparse when the append flips the scrollbar on" do
    s = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 20)

    # Interior width 12, no border/padding. `content_margin_x` reserves 1 column
    # once the bar shows, so a 12-char line is one wrapped line without the bar
    # but two with it. Viewport content height is 5 rows: >5 wrapped lines
    # overflow and summon the AsNeeded bar.
    box = Widget::Box.new(
      parent: s, top: 0, left: 0, width: 12, height: 5,
      scrollable: true, scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded)

    # Five short lines: 5 wrapped lines, no overflow, no scrollbar yet.
    box.content = "a\nb\nc\nd\ne"
    box.process_content
    box.content_margin_x.should eq 0

    # Append a full-width (12-char) line. Total becomes 6 wrapped-if-no-bar
    # lines, which overflows and flips the bar on; with the bar the 12-char line
    # itself wraps to two, so a full reparse yields 7 wrapped lines.
    box.append_line "bbbbbbbbbbbb"

    # A freshly built widget with the identical total content, fully parsed, is
    # the ground truth.
    ref = Widget::Box.new(
      parent: s, top: 0, left: 5, width: 12, height: 5,
      scrollable: true, scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded)
    ref.content = "a\nb\nc\nd\ne\nbbbbbbbbbbbb"
    ref.process_content

    ref.content_margin_x.should eq 1
    ref._clines.lines.size.should eq 7

    # After the flipping append, the widget's wrapped lines must agree with the
    # ground truth (same count and same wrapping), not the stale pre-bar layout.
    box._clines.lines.size.should eq ref._clines.lines.size
    box._clines.lines.map(&.to_s).should eq ref._clines.lines.map(&.to_s)
  end

  it "leaves the fast path untouched when the append does not flip the bar" do
    s = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 20)

    box = Widget::Box.new(
      parent: s, top: 0, left: 0, width: 12, height: 5,
      scrollable: true, scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded)

    box.content = "a\nb"
    box.process_content
    box.content_margin_x.should eq 0

    # Two more short lines: still 4 wrapped lines, no overflow, bar stays off.
    box.append_line "cccccccccccc"
    box.content_margin_x.should eq 0

    ref = Widget::Box.new(
      parent: s, top: 0, left: 20, width: 12, height: 5,
      scrollable: true, scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded)
    ref.content = "a\nb\ncccccccccccc"
    ref.process_content

    box._clines.lines.map(&.to_s).should eq ref._clines.lines.map(&.to_s)
  end

  it "stays consistent across a run of appends that crosses the threshold" do
    s = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 20)

    box = Widget::Box.new(
      parent: s, top: 0, left: 0, width: 12, height: 5,
      scrollable: true, scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded)
    box.content = "a"
    box.process_content

    lines = ["a"]
    6.times do
      line = "wwwwwwwwwwww" # 12 columns: two wrapped lines once the bar shows
      box.append_line line
      lines << line
    end

    ref = Widget::Box.new(
      parent: s, top: 0, left: 20, width: 12, height: 5,
      scrollable: true, scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AsNeeded)
    ref.content = lines.join("\n")
    ref.process_content

    box.content_margin_x.should eq ref.content_margin_x
    box._clines.lines.map(&.to_s).should eq ref._clines.lines.map(&.to_s)
  end
end
