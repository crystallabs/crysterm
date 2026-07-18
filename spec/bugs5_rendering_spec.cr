require "./spec_helper"

include Crysterm

# BUGS5 §10: wide-glyph EOL guard checked the CONTENT REGION (`xl`) but not the
# SCREEN width.
#
# `src/widget_rendering.cr:433` blanked a width-2 lead cell only when its
# continuation would fall at/after the content-region right edge (`!(x + 1 <
# xl)`). But screen rows are exactly `awidth` cells wide, so `line[x + 1]?` is
# nil whenever `x + 1 >= awidth`. Under the default `Overflow::Ignore`, a widget
# placed partly off the right edge keeps `xl > awidth` (`coords` only clamps
# `xl` for `ShrinkWidget`/`MoveWidget`). A wide glyph at the LAST screen column
# (`x == awidth - 1`, so `x + 1 == awidth`) then satisfied `x + 1 < xl` — so it
# was NOT blanked — while the continuation-claim block (`window_drawing.cr:604`)
# saw `line[x + 1]? == nil` and recorded no continuation. The lead was left as an
# unpaired `width == 2` cell and `draw` emitted a 2-column glyph into the single
# remaining column → cursor/glyph desync.
#
# Fix: blank the lead when the continuation cell does not exist in the buffer,
# making the guard the exact complement of the continuation-claim gate
# (`(x + 1 < xl) && line[x + 1]?`).

private def fu_screen(width, height)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false)
  s.full_unicode = true
  pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
  s
end

describe "BUGS5: wide glyph at the last screen column (content region past screen edge)" do
  # A borderless box placed partly off the right edge keeps `xl > awidth`.
  # `left: 5, width: 4` on a 6-wide screen → content region xi=5, xl=9, while the
  # last (and only reachable) screen column is 5. A wide glyph there has NO
  # continuation cell in the row (`line[6]?` is nil), yet `x + 1 (6) < xl (9)`, so
  # the old guard left it as an unpaired width-2 cell.
  it "blanks a wide glyph whose continuation falls off the screen edge" do
    s = fu_screen(6, 1)
    Widget::Box.new parent: s, top: 0, left: 5, width: 4, content: "漢"
    s._render
    line = s.lines[0]

    # Lead cell blanked to a space, not left as an unpaired '漢'.
    line[5].char.should eq ' '
    line[5].width.should eq 1
    line[5].continuation?.should be_false
    line[5].grapheme_overlay.should be_nil
  end

  # Broader invariant: across a sweep of left offsets that push the content region
  # past the screen edge, no on-screen width-2 cell is ever left without an
  # in-buffer continuation cell immediately after it.
  it "never leaves a width-2 cell at/over the screen edge without a continuation" do
    {"漢", "a漢", "aa漢", "😀", "漢漢"}.each do |content|
      (2..5).each do |left|
        s = fu_screen(6, 1)
        Widget::Box.new parent: s, top: 0, left: left, width: 4, content: content
        s._render
        line = s.lines[0]
        (0...(s.awidth)).each do |x|
          if line[x].width == 2
            # A width-2 lead cell must have an in-buffer continuation cell.
            line[x + 1]?.should_not be_nil
            line[x + 1].continuation?.should be_true
          end
        end
      end
    end
  end

  # Control: when the continuation cell fits within the screen row (content region
  # inside `awidth`), the wide glyph lays across two cells as usual.
  it "lays a wide glyph across two cells when the continuation fits on screen" do
    s = fu_screen(6, 1)
    Widget::Box.new parent: s, top: 0, left: 2, width: 4, content: "漢"
    s._render
    line = s.lines[0]

    line[2].char.should eq '漢'
    line[2].width.should eq 2
    line[3].continuation?.should be_true
  end
end
