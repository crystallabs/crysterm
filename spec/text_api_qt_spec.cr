require "./spec_helper"

include Crysterm

private def mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Covers the Qt-shaped public text API added/renamed on the text widgets:
#
#   * `LineEdit`/`PlainTextEdit`/`TextEdit` gained `#text`/`#text=` (Qt's
#     `QLineEdit::text`), `#select_all`, `#insert_text`, and `#clear` (was
#     `clear_value`).
#   * `FlatBuffer#value=` now emits `Event::TextChanged` on a *programmatic*
#     set — Qt's `QLineEdit::textChanged` fires on `setText`, not only on
#     typing. Previously only the document-backed editors notified, so a
#     `LineEdit` binding never saw `input.value = "x"`.
#   * `LineEdit`'s contradictory `secret`/`censor` Bools became one
#     `LineEdit::EchoMode` enum (Qt's `echoMode`).
#   * `Widget#rendered_content`/`#rendered_text` (were `get_content`/`get_text`)
#     report the PARSED/WRAPPED view, which is deliberately *not* the inverse of
#     the raw `#content`.
describe "Qt-shaped text API" do
  describe "Event::TextChanged on a programmatic set" do
    it "emits on LineEdit#value= when the text actually changes" do
      s = mem_screen
      le = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
      seen = [] of String
      le.on(Crysterm::Event::TextChanged) { |e| seen << e.value }

      le.value = "hello"
      seen.should eq ["hello"]
    end

    it "does not emit when the set does not change the text" do
      s = mem_screen
      le = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "same"
      seen = [] of String
      le.on(Crysterm::Event::TextChanged) { |e| seen << e.value }

      le.value = "same"
      seen.should be_empty
    end

    it "does not emit on the once-per-frame redisplay (value = nil)" do
      s = mem_screen
      le = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "x"
      seen = [] of String
      le.on(Crysterm::Event::TextChanged) { |e| seen << e.value }

      s._render
      s._render
      seen.should be_empty
    end

    it "emits via #text=, #clear and the LineEdit history walk" do
      s = mem_screen
      le = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
      seen = [] of String
      le.on(Crysterm::Event::TextChanged) { |e| seen << e.value }

      le.text = "one"
      le.clear
      seen.should eq ["one", ""]
    end
  end

  describe "#text / #text= " do
    it "round-trips on LineEdit and tracks #value" do
      s = mem_screen
      le = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
      le.text = "abc"
      le.text.should eq "abc"
      le.value.should eq "abc"
      le.value = "def"
      le.text.should eq "def"
    end

    it "round-trips on Label (Qt QLabel#text) as the raw content" do
      s = mem_screen
      l = Crysterm::Widget::Label.new parent: s, top: 0, left: 0, width: 20, height: 1
      l.text = "{bold}hi{/bold}"
      # Raw: what went in comes back out, tags and all.
      l.text.should eq "{bold}hi{/bold}"
      l.content.should eq "{bold}hi{/bold}"
    end
  end

  describe "raw vs rendered content" do
    it "keeps #content raw while #rendered_text reports the parsed view" do
      s = mem_screen
      b = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3,
        parse_tags: true, content: "{bold}hi{/bold}"
      s._render
      # The trap this pair is named for: they are NOT inverses.
      b.content.should eq "{bold}hi{/bold}"
      b.rendered_text.should eq "hi"
      b.rendered_content.should contain "\e["
    end

    it "exposes #line / #lines / #screen_lines" do
      s = mem_screen
      b = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5,
        content: "one\ntwo"
      s._render
      b.line(0).should eq "one"
      b.lines.should eq ["one", "two"]
      b.screen_lines.size.should eq 2
    end
  end

  describe "LineEdit::EchoMode" do
    it "defaults to Normal and shows the value" do
      s = mem_screen
      le = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 18, height: 1, content: "abcd"
      le.echo_mode.should eq Crysterm::Widget::LineEdit::EchoMode::Normal
      s._render
      le.@_value.should eq "abcd"
    end

    it "masks under Password and shows nothing under NoEcho, value intact" do
      s = mem_screen
      le = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 18, height: 1,
        content: "abcd", echo_mode: :password
      s._render
      le.@_value.should eq "****"
      le.value.should eq "abcd"

      le.echo_mode = Crysterm::Widget::LineEdit::EchoMode::NoEcho
      le.refresh_value
      le.@_value.should eq ""
      le.value.should eq "abcd"
    end

    it "PasswordEchoOnEdit masks only while unfocused" do
      s = mem_screen
      le = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 18, height: 1,
        content: "abcd", echo_mode: :password_echo_on_edit
      # A second field to park focus on: the sole focusable widget is focused
      # automatically, which for this mode means "being edited".
      other = Crysterm::Widget::LineEdit.new parent: s, top: 1, left: 0, width: 18, height: 1

      le.focus
      le.refresh_value
      le.@_value.should eq "abcd"

      # Focus elsewhere ⇒ resolves to Password and re-masks.
      other.focus
      le.focused?.should be_false
      le.refresh_value
      le.@_value.should eq "****"
    end
  end

  describe "#select_all / #insert_text" do
    it "select_all spans the whole buffer" do
      s = mem_screen
      le = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "hello"
      le.selection?.should be_false
      le.select_all
      le.selection?.should be_true
      le.selected_text.should eq "hello"
      le.cursor_pos.should eq 5
    end

    it "insert_text inserts at the cursor and replaces a selection" do
      s = mem_screen
      le = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "hello"
      le.cursor_pos = 0
      le.insert_text "X"
      le.value.should eq "Xhello"

      le.select_all
      le.insert_text "bye"
      le.value.should eq "bye"
      le.selection?.should be_false
    end

    it "insert_text emits TextChanged, and is a no-op for an empty insert" do
      s = mem_screen
      le = Crysterm::Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "a"
      seen = [] of String
      le.on(Crysterm::Event::TextChanged) { |e| seen << e.value }

      le.insert_text "b"
      le.insert_text ""
      seen.should eq ["ab"]
    end
  end

  describe "PlainTextEdit plain-text API" do
    it "to_plain_text / plain_text= / append_plain_text" do
      s = mem_screen
      pte = Crysterm::Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 20, height: 5
      pte.plain_text = "one"
      pte.to_plain_text.should eq "one"

      pte.append_plain_text "two"
      pte.to_plain_text.should eq "one\ntwo"

      # Appending to an empty document does not open with a blank line.
      pte.plain_text = ""
      pte.append_plain_text "first"
      pte.to_plain_text.should eq "first"
    end
  end
end
