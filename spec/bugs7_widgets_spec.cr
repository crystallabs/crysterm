require "./spec_helper"

include Crysterm

# Regression specs for the BUGS7 widget-behavior fixes.
#
# * `LineEdit#compute_display` horizontal scroll must track/clamp in display
#   columns, so the caret/tail stays on-screen for wide (CJK) content.
# * `ActionBar#remove_item` must renumber auto prefixes so the shown `N:` labels
#   stay in step with the raw-index number-key selection.
# * `Menu` Enter/Escape must not activate/cancel item 0 while no row is
#   highlighted; menu row widths must use display width.
# * `ComboBox#cycle` wraps a negative delta via `%` (no dead guard needed).
# * `ProgressBar#maximum=`/`#set_range` must not emit a spurious `Event::Completed`
#   when the range is shrunk onto the current value.

private def uni_window(w = 20, h = 6)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, full_unicode: true)
end

describe "BUGS7 LineEdit wide-character horizontal scroll" do
  it "keeps the tail (and caret) on-screen for full-width CJK content" do
    s = uni_window
    # Inner text width ~= awidth - ihorizontal - 1; keep the box narrow.
    input = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 8, height: 1
    s._render

    value = "漢字漢字漢字漢字漢字" # 10 CJK glyphs, 20 display columns
    input.value = value  # external set → caret to the end
    s._render

    shown = input.content.to_s
    # The window must show the tail near the caret, i.e. it ends with the last
    # glyph — not the head (which is what the pre-fix codepoint/column unit mix
    # produced, leaving the caret far off-screen).
    shown.should_not be_empty
    shown.ends_with?("字").should be_true
    shown.should_not start_with("漢字漢字漢") # not stuck showing the head
  end

  it "still shows the whole value when it fits" do
    s = uni_window
    input = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 12, height: 1
    s._render
    input.value = "漢字"
    s._render
    input.content.to_s.should contain "漢字"
  end
end

describe "BUGS7 ActionBar#remove_item renumbers auto prefixes" do
  it "renumbers auto prefixes and keeps number-key selection in step" do
    s = uni_window 40, 3
    fired = [] of String
    bar = Widget::ListBar.new parent: s, top: 0, left: 0, width: 40, height: 1,
      auto_command_keys: true
    bar.items = ({
      "open" => -> { fired << "open"; nil },
      "save" => -> { fired << "save"; nil },
      "quit" => -> { fired << "quit"; nil },
    })
    s._render

    bar.commands.map(&.prefix).should eq ["1", "2", "3"]

    bar.remove_item 0                               # remove "open"; backing list is now [save, quit]
    bar.commands.map(&.prefix).should eq ["1", "2"] # renumbered

    # Number-key '1' now selects the first remaining command ("save"), which is
    # also the one now labeled "1" — the pre-fix desync selected "save" while it
    # was still labeled "2".
    bar.on_keypress Crysterm::Event::KeyPress.new('1', nil)
    fired.last.should eq "save"
  end
end

describe "BUGS7 Menu Enter/Escape reveal gate" do
  it "reveals the highlight on the first Enter instead of activating item 0" do
    s = uni_window
    activated = [] of String
    menu = Widget::Menu.new parent: s
    menu.add_action("Open") { activated << "Open" }
    menu.add_action("Save") { activated << "Save" }
    menu.popup 1, 1 # opens with no row highlighted

    menu.on_keypress Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter)
    activated.empty?.should be_true # first Enter only revealed the highlight

    menu.on_keypress Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter)
    activated.should eq ["Open"] # second Enter activates the highlighted item
  end
end

describe "BUGS7 Menu row width uses display width" do
  it "sizes a CJK label wider than an equal-codepoint-count ASCII label" do
    s = uni_window
    cjk = Widget::Menu.new parent: s
    cjk.add_action "漢字" # 2 codepoints, 4 display columns
    cjk.popup 1, 1

    ascii = Widget::Menu.new parent: s
    ascii.add_action "ab" # 2 codepoints, 2 display columns
    ascii.popup 1, 1

    # Same codepoint count, so the pre-fix (codepoint) width would be identical;
    # the display-width fix makes the CJK menu exactly 2 columns wider.
    (cjk.width.as(Int) - ascii.width.as(Int)).should eq 2
  end
end

describe "BUGS7 ComboBox#cycle wraps a negative delta" do
  it "wraps to the last option when cycling below zero" do
    cb = Widget::ComboBox.new options: ["a", "b", "c"]
    cb.current_index.should eq 0
    cb.cycle -1
    cb.current_index.should eq 2 # wrapped
    cb.cycle 1
    cb.current_index.should eq 0 # wrapped back
  end
end

describe "BUGS7 ProgressBar does not complete on a range shrink" do
  it "does not emit Event::Completed when the maximum drops onto the value" do
    pb = Widget::ProgressBar.new value: 100, minimum: 0, maximum: 100
    completes = 0
    pb.on(Crysterm::Event::Completed) { completes += 1 }

    pb.maximum = 50 # re-clamps 100 -> 50; a reconfiguration, not a completion
    pb.value.should eq 50
    completes.should eq 0
  end

  it "still emits Event::Completed when the value rises to the maximum" do
    pb = Widget::ProgressBar.new value: 0, minimum: 0, maximum: 100
    completes = 0
    pb.on(Crysterm::Event::Completed) { completes += 1 }

    pb.value = 100
    completes.should eq 1
  end
end
