require "./spec_helper"

include Crysterm

# Regression specs for BUGS15 findings #17, #36, #45, #46.
#
# Headless harness (like text_editing_keys_spec / textedit_render_spec): a
# `Window` over in-memory IOs driven by the synchronous `Window#_render`, with
# cells asserted straight off `Window#lines`.

private def bt_screen(width = 60, height = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false)
end

private def row_text(s, y, len)
  String.build { |io| len.times { |x| io << s.lines[y][x].char } }
end

private def em_row_text(em, row, len)
  String.build do |io|
    len.times { |x| io << (em.lines[row]?.try(&.[x]?).try(&.char) || ' ') }
  end
end

# ── #17: TERM is exported to the PTY child ───────────────────────────────────
describe "BUGS15 17: Widget::Terminal exports term_name as TERM to the child" do
  it "advertises the configured term_name to the spawned shell" do
    s = bt_screen 80, 24
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 40, height: 4,
      shell: "sh", args: ["-c", "printf 'TERM=[%s]' \"$TERM\"; sleep 5"],
      term_name: "xterm-crysterm17")
    s._render # bootstrap + spawn PTY
    em = term.emulator.not_nil!

    # Reader fiber pumps child output into the emulator asynchronously.
    150.times do
      break if em_row_text(em, 0, 40).includes?("TERM=[")
      sleep 30.milliseconds
    end

    em_row_text(em, 0, 40).includes?("TERM=[xterm-crysterm17]").should be_true
  ensure
    term.try &.kill
    s.try &.destroy
  end

  it "does not override an explicit TERM already present in the env" do
    s = bt_screen 80, 24
    env = {} of String => String?
    env["TERM"] = "myterm-explicit"
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 40, height: 4,
      shell: "sh", args: ["-c", "printf 'TERM=[%s]' \"$TERM\"; sleep 5"],
      term_name: "xterm-crysterm17", env: env)
    s._render
    em = term.emulator.not_nil!

    150.times do
      break if em_row_text(em, 0, 40).includes?("TERM=[")
      sleep 30.milliseconds
    end

    em_row_text(em, 0, 40).includes?("TERM=[myterm-explicit]").should be_true
  ensure
    term.try &.kill
    s.try &.destroy
  end
end

# ── #36: text-editor caret/click honor the ancestor-clip offset ───────────────
describe "BUGS15 36: text editor click/caret map through the clip-aware base" do
  it "position_at maps a click to the buffer line actually painted there" do
    s = bt_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 24, height: 6, scrollable: true
    pte = Widget::PlainTextEdit.new parent: outer, top: 0, left: 0, width: 20, height: 10,
      content: "line0\nline1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9"
    # Spacer below so the container has enough content to scroll the editor's
    # top rows above the viewport (spilling scroll into child_base, which is
    # what shifts child widgets — see widget_position.cr:510).
    Widget::Box.new parent: outer, top: 10, left: 0, width: 1, height: 30
    s._render

    # Scroll so the editor's top 3 rows are clipped: its first visible row now
    # shows buffer line 3 (lpos.base == 3, the editor's own child_base still 0).
    outer.scroll_to 8
    s._render
    lp = pte.lpos.not_nil!
    lp.base.should eq 3
    pte.child_base.should eq 0

    # Clicking the first visible row must land on buffer line 3, not line 0.
    pos = pte.position_at(lp.xi, lp.yi)
    pte.value[0...pos].count('\n').should eq 3
  end

  it "_update_cursor places the caret at the row where its line is painted" do
    s = bt_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 24, height: 6, scrollable: true
    pte = Widget::PlainTextEdit.new parent: outer, top: 0, left: 0, width: 20, height: 10,
      content: "line0\nline1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9"
    Widget::Box.new parent: outer, top: 10, left: 0, width: 1, height: 30
    s._render
    outer.scroll_to 8
    s._render
    lp = pte.lpos.not_nil!
    lp.base.should eq 3

    pte.focus
    # Caret on buffer line 3 (start of "line3": 3 * len("lineN\n") == 18).
    pte.cursor_pos = 18
    pte._update_cursor

    # Buffer line 3 is painted at the viewport top (lpos.yi), so the hardware
    # caret must land there — not 3 rows lower (the pre-fix @child_base math).
    s.tput.cursor.y.should eq(lp.yi + s.render_row_offset)
  end
end

# ── #45: Terminal#draw maps the clipped grid region correctly ─────────────────
describe "BUGS15 45: clipped Widget::Terminal shows the correct grid region" do
  it "paints the scrolled-into-view emulator rows, not the top-left corner" do
    s = bt_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 6, scrollable: true
    term = Crysterm::Widget::Terminal.new(
      parent: outer, top: 0, left: 0, width: 20, height: 10,
      handler: ->(_d : String) { })
    # Spacer so the container can scroll the terminal's top rows off-viewport.
    Widget::Box.new parent: outer, top: 10, left: 0, width: 1, height: 30
    s._render # bootstrap the emulator (20x10)

    # Fill each emulator row with its own digit so a row is identifiable, and
    # park the cursor at row 5, col 3 (1-based) — emulator (row 4, col 2).
    content = String.build do |io|
      10.times do |i|
        io << "\e[#{i + 1};1H"
        io << (('0' + i).to_s * 20)
      end
      io << "\e[5;3H"
    end
    term.write content
    em = term.emulator.not_nil!
    em_row_text(em, 3, 1).should eq "3" # sanity: emulator row 3 holds '3'

    term.focus
    outer.scroll_to 8 # clip the terminal's top 3 rows
    s._render
    lp = term.lpos.not_nil!
    lp.base.should eq 3

    # Viewport top now shows emulator row 3; the row two below shows row 5.
    s.lines[lp.yi][lp.xi].char.should eq '3'
    s.lines[lp.yi + 2][lp.xi].char.should eq '5'

    # The cursor (emulator row 4) maps to viewport row 1 (4 - base 3): the
    # block cursor inverts that cell. Pre-fix it drew 3 rows too low.
    (Attr.flags(s.lines[lp.yi + 1][lp.xi + 2].attr) & Attr::REVERSE).should_not eq 0
  ensure
    term.try &.kill
    s.try &.destroy
  end
end

# ── #46: ranged extra selections honor the row's decoration offset ────────────
describe "BUGS15 46: ranged extra selections use the row decoration offset" do
  it "highlights the selected text on a decorated (list) row, not the marker" do
    s = bt_screen 40, 8
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8
    te.auto_formatting = Widget::TextEdit::AutoFormatting::BulletList
    "- one".each_char { |c| te._listener Crysterm::Event::KeyPress.new(c) }
    s._render
    # Row renders as "• one": marker at cols 0-1, text "one" at cols 2-4.
    row_text(s, 0, 5).should eq "• one"

    # A ranged extra selection over the whole word "one" (document 0..3).
    cur = TextCursor.new(te.document, 0)
    cur.set_position(3, TextCursor::MoveMode::KeepAnchor)
    te.extra_selections = [
      Widget::TextEdit::ExtraSelection.new(cur, TextCharFormat.new(underline: true), false),
    ]
    s._render

    # Underline must land on the text cells (2,3,4), offset past the marker —
    # crucially col 4 ('e'), which the pre-fix text-relative range never reached.
    (Attr.flags(s.lines[0][2].attr) & Attr::UNDERLINE).should_not eq 0
    (Attr.flags(s.lines[0][3].attr) & Attr::UNDERLINE).should_not eq 0
    (Attr.flags(s.lines[0][4].attr) & Attr::UNDERLINE).should_not eq 0
    # The marker cells and the cell past the word stay un-highlighted.
    (Attr.flags(s.lines[0][0].attr) & Attr::UNDERLINE).should eq 0
    (Attr.flags(s.lines[0][1].attr) & Attr::UNDERLINE).should eq 0
    (Attr.flags(s.lines[0][5].attr) & Attr::UNDERLINE).should eq 0
  end
end
