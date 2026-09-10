require "./spec_helper"

include Crysterm

# `Mixin::LineContent` seeding semantics: the logical-line editors distinguish
# a widget with NO logical lines from one holding a single EMPTY logical line,
# even though both have blank `#content` and an empty `@wrapped_lines.fake`.
# The first `#append_line` into a line-less widget seeds line 0; once a line
# editor has written the widget's lines, an empty first line counts as a line
# and the next append lands after it. A direct `#set_content` re-arms seeding.

describe "Mixin::LineContent empty-line seeding" do
  it "keeps an empty first Log line: add \"\" then add \"x\" yields two lines" do
    s = headless_screen(80, 24)
    log = Widget::Log.new parent: s, top: 0, left: 0, width: 20, height: 6

    log.add ""
    log.add "x"

    log.lines.should eq ["", "x"]
    log.line(0).should eq ""
    log.line(1).should eq "x"
  end

  it "keeps transcript line indices aligned when the first entry renders empty" do
    s = headless_screen(60, 20)
    t = Widget::Chat::Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10

    # A diff entry carries no prefix glyph, so an empty body renders as exactly
    # one empty logical line.
    t.append :diff, ""
    t.append :diff, "second"

    t.entries.size.should eq 2
    t.lines.size.should eq 2
    t.line(0).should eq ""
    t.line(1).should eq "second"

    # The third entry's start offset (2) must address the widget's third line.
    t.append :diff, "third"
    t.lines.should eq ["", "second", "third"]
  end

  it "splices the tail entry at its bookkept start line after an empty first entry" do
    s = headless_screen(60, 20)
    t = Widget::Chat::Transcript.new parent: s, top: 0, left: 0, width: 50, height: 10

    t.append :diff, ""
    t.append :diff, "second"

    # A rewrite (not pure growth) deletes and re-inserts at the entry's start
    # line, which is 1 — the empty entry still owns line 0.
    t.update_last(&.text=("changed"))

    t.entries.size.should eq 2
    t.lines.should eq ["", "changed"]
  end

  it "appends a plain first line without a leading blank" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6

    box.append_line "a"

    box.lines.should eq ["a"]
    box.line(0).should eq "a"

    box.append_line "b"
    box.lines.should eq ["a", "b"]
  end

  it "treats content cleared with set_content as line-less again" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6

    box.append_line ""
    box.set_content "seeded"
    box.set_content ""

    # Seeding is re-armed, so the next append starts at line 0.
    box.append_line "y"
    box.lines.should eq ["y"]
  end

  it "deletes the empty first line and re-seeds on the next append" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6

    box.append_line ""
    box.delete_line
    box.lines.should eq [] of String

    box.append_line "a"
    box.lines.should eq ["a"]
  end

  it "inserts after an empty first line with the no-index insert_line" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6

    box.append_line ""
    # One empty logical line, even though the content string is blank.
    box.lines.should eq [""]

    box.insert_line "tail"
    box.lines.should eq ["", "tail"]
  end
end
