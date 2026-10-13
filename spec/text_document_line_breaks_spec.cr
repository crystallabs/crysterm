require "./spec_helper"

include Crysterm

# Line breaks other than `'\n'`: Qt's `QTextCursor::insertText` (behind
# `setPlainText`, `fromPlainText` and every insertion) takes `"\r\n"` and a
# lone `'\r'` as a paragraph break as it takes `'\n'`, so no block holds a
# `'\r'`. A document here kept the `'\r'` at the end of every block of a
# CRLF text, and a line-anchored pattern over a block's text (a closing
# fence, a rule, an empty list item) no longer matched it.

private def block_texts(doc : TextDocument) : Array(String)
  doc.blocks.map(&.text)
end

describe "TextDocument line breaks" do
  it "takes \\r\\n and a lone \\r as block breaks in set_plain_text" do
    doc = TextDocument.new("a\r\nb\rc\n\r\nd")
    block_texts(doc).should eq ["a", "b", "c", "", "d"]
    doc.to_plain_text.should eq "a\nb\nc\n\nd"
    doc.set_plain_text("x\r\n")
    block_texts(doc).should eq ["x", ""]
  end

  it "takes them as block breaks in an insertion, the size counted after" do
    doc = TextDocument.new("ab")
    c = doc.cursor(1)
    c.insert_text("1\r\n2\r3")
    doc.to_plain_text.should eq "a1\n2\n3b"
    c.position.should eq 6
    doc.undo
    doc.to_plain_text.should eq "ab"
    doc.redo
    doc.to_plain_text.should eq "a1\n2\n3b"
  end

  it "takes them in replace_plain_text, a CRLF copy of the text being no change" do
    doc = TextDocument.new("one\ntwo")
    doc.replace_plain_text("one\r\ntwo").should be_false
    doc.replace_plain_text("one\r\n2\r\n").should be_true
    doc.to_plain_text.should eq "one\n2\n"
  end

  it "takes them in a plain-text fragment" do
    frag = TextDocumentFragment.from_plain_text("a\r\nb\rc")
    frag.blocks.map(&.text).should eq ["a", "b", "c"]
  end

  it "imports CRLF markdown as its LF copy" do
    src = "# T\n\n```\ncode\n```\n\nafter\n\n---\n\n- item\n"
    crlf = TextDocument.from_markdown(src.gsub("\n", "\r\n"))
    lf = TextDocument.from_markdown(src)
    crlf.to_plain_text.should eq lf.to_plain_text
    block_texts(crlf).none?(&.includes?('\r')).should be_true
    crlf.blocks.size.should eq lf.blocks.size
  end

  it "streams CRLF markdown as its LF copy, a \\r\\n split across chunks one break" do
    src = "para one\n\n```\ncode\n```\n\npara two\n\nlast\n"
    crlf = src.gsub("\n", "\r\n")
    doc = TextDocument.new
    # Cut between every "\r" and its "\n".
    crlf.split(/(?<=\r)/).each { |chunk| doc.append_markdown chunk }
    doc.flush_markdown
    doc.to_plain_text.should eq TextDocument.from_markdown(src).to_plain_text
    block_texts(doc).none?(&.includes?('\r')).should be_true
  end

  it "releases streamed markdown at a blank line made of lone \\r breaks" do
    doc = TextDocument.new
    doc.append_markdown "first\r\rsecond\r\r"
    doc.to_plain_text.should start_with "first"
  end
end

describe "Neovim::Handler and a \\r in a line" do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  it "has Neovim take the lines the widget split at a \\r" do
    window = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 10, default_quit_keys: false)
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "x\n"
    h = Crysterm::Neovim::Handler.new
    h.attach(w).should be_true
    h.input "ccab<C-v><CR>cd<Esc>"
    w.value.should eq "ab\ncd\n"
    # Neovim has two lines now: deleting the first leaves the second.
    h.input "ggdd"
    w.value.should eq "cd\n"
  ensure
    h.try &.detach
    window.try &.destroy
  end
end
