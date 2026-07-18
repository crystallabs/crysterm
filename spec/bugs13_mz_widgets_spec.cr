require "./spec_helper"

include Crysterm

# BUGS13 M-Z assorted widget regression coverage:
#   M1  — Pine Compose#reset must clear the body's *document*, not just the
#         display, so the old body can't resurrect.
#   M5  — TabWidget#remove_tab keeps the current page current when a
#         different tab is removed.
#   M7  — ToolTip sizes itself by display width (CJK/emoji).
#   M8  — StatusBar permanent sections right-align/truncate by display width.
#   M11 — a hidden Wizard must not consume window Enter/Escape.
#   M13 — ToolBox#add_item while hidden must not create a permanently
#         invisible header.
#   M15 — ItemView's incremental-search box is rebuilt on the current window
#         after a cross-window move.

private def wdg_screen(width = 40, height = 15)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

private class SearchSpyList < Crysterm::Widget::List
  def spy_search_box
    ensure_search_box
  end
end

describe "BUGS13 M1: Pine Compose#reset clears the document" do
  it "resets the body's authoritative buffer, not just the display" do
    s = wdg_screen(60, 20)
    compose = Widget::Pine::Compose.new parent: s, width: 60, height: 20
    compose.body.value = "old body text"
    compose.values["body"].should eq "old body text"

    compose.reset
    # `set_content ""` only blanked the display; the document (what #values
    # reads and what the next keystroke re-sets) still held the old body.
    compose.values["body"].should eq ""
    compose.body.value.should eq ""
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 M5: TabWidget#remove_tab keeps the current page" do
  it "keeps the current page when removing a preceding tab" do
    s = wdg_screen
    tw = Widget::TabWidget.new parent: s, width: 30, height: 8
    pa = Widget::Box.new(content: "a")
    pb = Widget::Box.new(content: "b")
    pc = Widget::Box.new(content: "c")
    tw.add_tab "A", pa
    tw.add_tab "B", pb
    tw.add_tab "C", pc

    tw.current_index = 2
    tw.current_widget.should eq pc

    tw.remove_tab 0
    # Qt's removeTab keeps the current page; the bug jumped the view to the
    # removed tab's neighbor (B).
    tw.current_widget.should eq pc
    tw.current_index.should eq 1
  ensure
    s.try &.destroy
  end

  it "falls back to a neighbor when removing the current tab itself" do
    s = wdg_screen
    tw = Widget::TabWidget.new parent: s, width: 30, height: 8
    pa = Widget::Box.new(content: "a")
    pb = Widget::Box.new(content: "b")
    pc = Widget::Box.new(content: "c")
    tw.add_tab "A", pa
    tw.add_tab "B", pb
    tw.add_tab "C", pc

    tw.current_index = 1
    tw.remove_tab 1
    tw.current_widget.should eq pc # the neighbor at the same index
    tw.current_index.should eq 1
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 M7: ToolTip sizes by display width" do
  it "sizes a CJK tooltip to its cell width" do
    s = wdg_screen
    s.full_unicode = true
    pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
    tt = Widget::ToolTip.new parent: s
    tt.show_at 0, 0, "日本語"
    # 6 display cells + 1 leading/trailing pad cell each side + insets;
    # codepoint counting (3) clipped the text inside the box.
    tt.width.should eq 6 + 2 + tt.ihorizontal
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 M8: StatusBar permanent sections use display width" do
  it "right-aligns a wide-char section by cells" do
    s = wdg_screen(20, 3)
    s.full_unicode = true
    pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
    bar = Widget::StatusBar.new parent: s, top: 0, left: 0, width: 20, height: 1
    bar.add_permanent "日本語" # 6 cells
    s._render
    # Starts at xl - 6 == 14, not xl - .size == 17.
    s.lines[0][14].char.should eq '日'
  ensure
    s.try &.destroy
  end

  it "left-truncates an overflowing run by display cells" do
    s = wdg_screen(6, 3)
    s.full_unicode = true
    pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
    bar = Widget::StatusBar.new parent: s, top: 0, left: 0, width: 6, height: 1
    bar.add_permanent "ABCDE日本" # 9 cells into 6
    s._render
    # Must drop A,B,C (3 cells) keeping "DE日本" (6 cells) — the codepoint
    # slice dropped only one character and started the run off-cell.
    s.lines[0][0].char.should eq 'D'
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 M11: hidden Wizard stands down from Enter/Escape" do
  it "ignores window Enter/Escape while hidden, acts when visible" do
    s = wdg_screen
    wiz = Widget::Wizard.new parent: s, width: 30, height: 10
    wiz.add_page "P1", Widget::Box.new(content: "one")
    wiz.add_page "P2", Widget::Box.new(content: "two")
    cancelled = 0
    wiz.on(Crysterm::Event::Cancelled) { cancelled += 1 }

    wiz.current_index.should eq 0
    wiz.hide

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Enter)
    wiz.current_index.should eq 0 # used to advance while invisible
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Escape)
    cancelled.should eq 0 # used to emit Cancel while invisible

    wiz.show
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Enter)
    wiz.current_index.should eq 1
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Escape)
    cancelled.should eq 1
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 M13: ToolBox#add_item while hidden" do
  it "creates a header that becomes visible when the toolbox is shown" do
    s = wdg_screen
    tb = Widget::ToolBox.new parent: s, width: 20, height: 10
    tb.hide
    tb.add_item "General", Widget::Box.new(content: "x")
    tb.show
    s._render

    header = tb.sections[0].header
    # The header used to dup the toolbox's hidden style and stay invisible
    # forever (nothing re-shows section headers).
    header.style.visible?.should be_true
    header.visible_in_tree?.should be_true
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 M15: search box re-homed after a window move" do
  it "rebuilds the memoized search box on the current window" do
    s1 = wdg_screen
    s2 = wdg_screen
    list = SearchSpyList.new parent: s1, top: 0, left: 0, width: 10, height: 5
    list.items = ["alpha", "beta"]

    box1 = list.spy_search_box
    box1.window?.should eq s1

    s1.remove list
    s2.append list

    box2 = list.spy_search_box
    box2.same?(box1).should be_false # stale satellite was dropped
    box2.window?.should eq s2
    s1.children.includes?(box1).should be_false
  ensure
    s1.try &.destroy
    s2.try &.destroy
  end
end
