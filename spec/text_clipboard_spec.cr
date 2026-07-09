require "./spec_helper"

include Crysterm

# Rich clipboard (TEXTEDIT.md Phase 3): the in-process clipboard carries a
# `TextDocumentFragment` alongside its plain text; the OSC-52/terminal side
# stays text-only. Copy sets both; paste prefers the fragment only where the
# buffer can take it (`Widget::TextEdit`'s document buffer) and only while
# the fragment is the freshest copy. Headless harness like
# `text_editing_keys_spec.cr`: keystrokes fed straight through `#_listener`.

private def clip_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24)
end

private def ctl(k : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', k
end

private def new_te(s, content = "")
  te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8, content: content
  s._render
  te
end

# Selects `[from, to)` in a TextEditing widget the way the mouse path does.
private def select_range(w, from, to)
  w.cursor_pos = to
  w.selection_anchor = from
end

private def app_clipboard(s)
  (s.application || Crysterm::Application.global).clipboard
end

describe "rich clipboard" do
  it "rich-copies a TextEdit selection: fragment + plain text" do
    s = clip_screen
    te = new_te s, "hello world"
    te.document.apply_char_format(0, 5, TextCharFormat.new(bold: true, fg: 0xFF0000))
    select_range te, 0, 7
    te._listener ctl(::Tput::Key::CtrlC)

    clip = app_clipboard(s)
    clip.text.should eq "hello w"
    frag = clip.fragment.not_nil!
    frag.to_plain_text.should eq "hello w"
    frag.blocks[0].fragments[0].format.bold?.should be_true
  end

  it "pastes the fragment into another TextEdit with formats intact, as one undo step" do
    s = clip_screen
    src = new_te s, "styled"
    src.document.apply_char_format(0, 6, TextCharFormat.new(italic: true, fg: 0x00FF00))
    select_range src, 0, 6
    src._listener ctl(::Tput::Key::CtrlC)

    dst = new_te s, "ab"
    dst.cursor_pos = 1
    dst._listener ctl(::Tput::Key::CtrlV)

    dst.value.should eq "astyledb"
    dst.cursor_pos.should eq 7
    dst.document.char_format_at(2).italic?.should be_true
    dst.document.char_format_at(2).fg.should eq 0x00FF00

    dst.undo.should be_true
    dst.value.should eq "ab"
  end

  it "replaces a selection on rich paste as a single undo step" do
    s = clip_screen
    src = new_te s, "NEW"
    select_range src, 0, 3
    src._listener ctl(::Tput::Key::CtrlC)

    dst = new_te s, "old text"
    select_range dst, 0, 3
    dst._listener ctl(::Tput::Key::CtrlV)
    dst.value.should eq "NEW text"

    dst.undo.should be_true
    dst.value.should eq "old text"
  end

  it "degrades to plain text when pasting into a flat buffer" do
    s = clip_screen
    src = new_te s, "styled"
    src.document.apply_char_format(0, 6, TextCharFormat.new(bold: true))
    select_range src, 0, 6
    src._listener ctl(::Tput::Key::CtrlC)

    le = Widget::LineEdit.new parent: s, left: 0, top: 10, width: 20, height: 1, content: ""
    s._render
    le._listener ctl(::Tput::Key::CtrlV)
    le.value.should eq "styled"
  end

  it "a fresher plain copy invalidates the fragment" do
    s = clip_screen
    src = new_te s, "rich"
    src.document.apply_char_format(0, 4, TextCharFormat.new(bold: true))
    select_range src, 0, 4
    src._listener ctl(::Tput::Key::CtrlC)
    app_clipboard(s).fragment.should_not be_nil

    # Plain copy from a flat-buffer widget wins (it's newer).
    le = Widget::LineEdit.new parent: s, left: 0, top: 10, width: 20, height: 1, content: "plain"
    s._render
    select_range le, 0, 5
    le._listener ctl(::Tput::Key::CtrlC)
    app_clipboard(s).fragment.should be_nil
    app_clipboard(s).text.should eq "plain"

    dst = new_te s, ""
    dst._listener ctl(::Tput::Key::CtrlV)
    dst.value.should eq "plain"
    dst.document.char_format_at(3).bold?.should be_false
  end

  it "an external OSC-52 reply invalidates the fragment; our own echo does not" do
    s = clip_screen
    te = new_te s, "mine"
    select_range te, 0, 4
    te._listener ctl(::Tput::Key::CtrlC)
    clip = app_clipboard(s)

    clip.refresh_from_terminal("mine") # our copy echoed back
    clip.fragment.should_not be_nil

    clip.refresh_from_terminal("external")
    clip.fragment.should be_nil
    clip.text.should eq "external"
  end

  it "pastes multi-block fragments across blocks" do
    s = clip_screen
    src = new_te s, "one\ntwo"
    src.document.apply_char_format(0, 3, TextCharFormat.new(underline: true))
    select_range src, 0, 7
    src._listener ctl(::Tput::Key::CtrlC)

    dst = new_te s, "XY"
    dst.cursor_pos = 1
    dst._listener ctl(::Tput::Key::CtrlV)
    dst.value.should eq "Xone\ntwoY"
    dst.document.char_format_at(2).underline?.should be_true
  end

  it "falls back to the truncating plain path when max_length is exceeded" do
    s = clip_screen
    src = new_te s, "abcdefgh"
    src.document.apply_char_format(0, 8, TextCharFormat.new(bold: true))
    select_range src, 0, 8
    src._listener ctl(::Tput::Key::CtrlC)

    dst = Widget::TextEdit.new parent: s, left: 0, top: 10, width: 40, height: 4,
      content: "12", max_length: 6
    s._render
    dst.cursor_pos = 2
    dst._listener ctl(::Tput::Key::CtrlV)

    # Plain path: truncated to the remaining room, unformatted.
    dst.value.should eq "12abcd"
    dst.document.char_format_at(3).bold?.should be_false
  end

  it "rich copy round-trips through the tags serialization of the fragment" do
    s = clip_screen
    te = new_te s, "tagged text"
    te.document.apply_char_format(0, 6, TextCharFormat.new(bold: true))
    select_range te, 0, 11
    te._listener ctl(::Tput::Key::CtrlC)

    frag = app_clipboard(s).fragment.not_nil!
    frag2 = TextDocumentFragment.from_tags(frag.to_tags)
    frag2.to_plain_text.should eq "tagged text"
    frag2.blocks[0].fragments[0].format.bold?.should be_true
  end
end
