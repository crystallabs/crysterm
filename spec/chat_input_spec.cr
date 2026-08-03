require "./spec_helper"

include Crysterm

# `Widget::Chat::Input`: submit/newline key semantics, input history walking,
# the prompt-gutter/rounded-border chrome, placeholder display, and
# auto-growing height.

private alias ChatInput = Crysterm::Widget::Chat::Input
private alias ChatGlyphs = Crysterm::Chat::Glyphs

private def new_input(s, **opts)
  w = ChatInput.new **opts.merge({parent: s, left: 0, top: 0, width: 40})
  s.repaint
  w
end

private def type_str(w, str : String)
  str.each_char { |c| w._listener kp(c) }
end

private def press(w, key : ::Tput::Key, char = '\0')
  w._listener kp(char, key)
end

private def press_enter(w)
  press w, ::Tput::Key::Enter, '\r'
end

# Shift+Enter only exists under an enhanced keyboard protocol, so it arrives
# with a rich `KeyEvent` carrying the modifier.
private def press_shift_enter(w)
  ke = ::Tput::KeyEvent.new 13, 'u', ::Tput::Modifiers::Shift
  w._listener Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter, key_event: ke)
end

private def collect_submits(w)
  got = [] of String
  w.on(Crysterm::Event::Submitted) { |e| got << e.value }
  got
end

describe Crysterm::Widget::Chat::Input do
  it "Enter submits: emits Submitted with the text, clears, records history" do
    s = headless_screen(60, 20)
    w = new_input s
    got = collect_submits w

    type_str w, "hello"
    press_enter w

    got.should eq ["hello"]
    w.value.should eq ""
    w.history.should eq ["hello"]
  end

  it "Enter on blank text is a no-op (no event, no history)" do
    s = headless_screen(60, 20)
    w = new_input s
    got = collect_submits w

    press_enter w
    type_str w, "   "
    press_enter w

    got.should be_empty
    w.history.should be_empty
  end

  it "Shift+Enter inserts a newline instead of submitting" do
    s = headless_screen(60, 20)
    w = new_input s
    got = collect_submits w

    type_str w, "ab"
    press_shift_enter w
    type_str w, "c"

    w.value.should eq "ab\nc"
    got.should be_empty
  end

  it "backslash + Enter inserts a newline (the escape is consumed)" do
    s = headless_screen(60, 20)
    w = new_input s
    got = collect_submits w

    type_str w, "ab\\"
    press_enter w
    got.should be_empty
    w.value.should eq "ab\n"

    type_str w, "c"
    press_enter w
    got.should eq ["ab\nc"]
    w.value.should eq ""
  end

  it "Up/Down walk the history and restore the stashed draft" do
    s = headless_screen(60, 20)
    w = new_input s

    type_str w, "one"
    press_enter w
    type_str w, "two"
    press_enter w

    type_str w, "dra"
    press w, ::Tput::Key::Up
    w.value.should eq "two"
    press w, ::Tput::Key::Up
    w.value.should eq "one"
    # At the oldest entry, Up stays put.
    press w, ::Tput::Key::Up
    w.value.should eq "one"

    press w, ::Tput::Key::Down
    w.value.should eq "two"
    # Down past the newest entry restores the draft.
    press w, ::Tput::Key::Down
    w.value.should eq "dra"
    press w, ::Tput::Key::Down
    w.value.should eq "dra"
  end

  it "gates history on the caret's line: Up moves the caret first in a multiline buffer" do
    s = headless_screen(60, 20)
    w = new_input s

    type_str w, "old"
    press_enter w

    type_str w, "x"
    press_shift_enter w
    type_str w, "y"
    # Caret movement maps through the rendered lines, so sync the display.
    s.repaint
    # Caret is at the end (last line, not first): Up is caret movement.
    press w, ::Tput::Key::Up
    w.value.should eq "x\ny"
    # Now on the first line: Up recalls history.
    press w, ::Tput::Key::Up
    w.value.should eq "old"
    # Recalled entry is single-line, so Down (last line) walks forward,
    # restoring the multiline draft.
    press w, ::Tput::Key::Down
    w.value.should eq "x\ny"
  end

  it "skips blank and immediately-repeated history entries" do
    s = headless_screen(60, 20)
    w = new_input s

    type_str w, "same"
    press_enter w
    type_str w, "same"
    press_enter w

    w.history.should eq ["same"]
  end

  it "draws the rounded border and the prompt chevron in the gutter" do
    s = headless_screen(60, 20)
    w = new_input s

    cell_char(s, 0, 0).should eq ChatGlyphs::ROUND_TL[0]
    cell_char(s, 39, 0).should eq ChatGlyphs::ROUND_TR[0]
    cell_char(s, 0, w.aheight - 1).should eq ChatGlyphs::ROUND_BL[0]
    cell_char(s, 39, w.aheight - 1).should eq ChatGlyphs::ROUND_BR[0]
    # Gutter: first cell inside the left border, first content row.
    cell_char(s, 1, 1).should eq ChatGlyphs::PROMPT[0]
  end

  it "shows the placeholder while empty and drops it on typing" do
    s = headless_screen(60, 20)
    w = new_input s, placeholder_text: "Type a message"
    s.repaint

    row_text(s, 1).should contain "Type a message"

    type_str w, "hi"
    s.repaint
    row_text(s, 1).should contain "hi"
    row_text(s, 1).should_not contain "Type a message"

    # Clearing (e.g. after submit) brings it back.
    press_enter w
    s.repaint
    row_text(s, 1).should contain "Type a message"
  end

  it "auto-grows with the line count up to max_height, and shrinks on clear" do
    s = headless_screen(60, 20)
    w = new_input s

    w.aheight.should eq 3 # 1 content row + border

    type_str w, "a"
    press_shift_enter w
    type_str w, "b"
    s.repaint
    w.aheight.should eq 4

    8.times do
      press_shift_enter w
      type_str w, "z"
    end
    s.repaint
    w.aheight.should eq 8 # capped

    press_enter w # submit clears
    s.repaint
    w.aheight.should eq 3
  end

  it "auto-grown height matches the newline count for empty, single and multi-line buffers" do
    s = headless_screen(60, 20)
    w = new_input s

    # One row per logical line (the document's block count), +2 border rows,
    # floored at one content row and capped at max_height 8 — including the
    # empty buffer (one empty block) and trailing-newline buffers (a trailing
    # empty line is a line).
    {"", "one", "a\nb", "a\nb\nc", "a\n", "\n\n", "1\n2\n3\n4\n5\n6\n7\n8"}.each do |text|
      w.value = text
      s.repaint
      w.aheight.should eq (text.count('\n') + 1 + 2).clamp(3, 8)
    end
  end

  it "does not auto-grow when constructed with an explicit height" do
    s = headless_screen(60, 20)
    w = new_input s, height: 5

    type_str w, "a"
    press_shift_enter w
    type_str w, "b"
    s.repaint
    w.aheight.should eq 5
    w.auto_grow?.should be_false
  end
end
