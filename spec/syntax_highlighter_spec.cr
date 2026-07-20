require "./spec_helper"

include Crysterm

# `SyntaxHighlighter` (TEXTEDIT.md Phase 4): per-block `highlight_block`
# overlays via `TextBlock#additional_formats`, automatic re-highlight on
# edits, and the user-state cascade for multi-line constructs.

# Highlights every digit run.
private class DigitHighlighter < Crysterm::SyntaxHighlighter
  def highlight_block(text)
    text.scan(/\d+/) do |md|
      set_format(md.begin(0), md[0].size, 0xFF0000)
    end
  end
end

# Multi-line `/* … */` comments: state 1 = "inside a comment".
private class CommentHighlighter < Crysterm::SyntaxHighlighter
  FMT = Crysterm::TextCharFormat.new(fg: 0x00FF00, italic: true)

  def highlight_block(text)
    pos = 0
    inside = previous_block_state == 1
    while pos <= text.size
      if inside
        stop = text.index("*/", pos)
        len = (stop ? stop + 2 : text.size) - pos
        set_format(pos, len, FMT)
        break self.current_block_state = 1 unless stop
        pos = stop + 2
        inside = false
      else
        start = text.index("/*", pos) || break
        pos = start
        inside = true
      end
    end
    self.current_block_state = 0 unless inside && current_block_state == 1
  end
end

private def digit_doc(text)
  doc = Crysterm::TextDocument.new(text)
  {doc, DigitHighlighter.new(doc)}
end

describe Crysterm::SyntaxHighlighter do
  it "overlays formats without touching fragments or plain text" do
    doc, _hl = digit_doc("ab 12 cd")
    doc.blocks[0].fragments.size.should eq 1
    doc.to_plain_text.should eq "ab 12 cd"
    runs = doc.blocks[0].render_runs
    runs.size.should eq 3
    runs[1].should eq({3, 5, TextCharFormat.new(fg: 0xFF0000)})
    runs[0][2].fg.should be_nil
  end

  it "keeps the overlay out of undo and interchange" do
    doc, _hl = digit_doc("x 1")
    doc.undo_available?.should be_false
    doc.to_tags.should eq "x 1"
  end

  it "re-highlights edited blocks" do
    doc, _hl = digit_doc("abc")
    doc.blocks[0].render_runs.size.should eq 1
    doc.insert_text(1, "77")
    runs = doc.blocks[0].render_runs
    runs[1][2].fg.should eq 0xFF0000
    runs[1][0].should eq 1
    runs[1][1].should eq 3
  end

  it "merges overlay patches over fragment formats" do
    doc = Crysterm::TextDocument.new("no 42")
    doc.apply_char_format(0, 5, TextCharFormat.new(bold: true))
    DigitHighlighter.new(doc)
    runs = doc.blocks[0].render_runs
    runs[1][2].bold?.should be_true
    runs[1][2].fg.should eq 0xFF0000
  end

  it "cascades multi-line state across blocks" do
    doc = Crysterm::TextDocument.new("a /* one\ntwo\nthree */ b")
    CommentHighlighter.new(doc)
    doc.blocks[0].user_state.should eq 1
    doc.blocks[1].user_state.should eq 1
    doc.blocks[2].user_state.should eq 0
    # The middle block is fully inside the comment.
    doc.blocks[1].render_runs[0][2].fg.should eq 0x00FF00
    doc.blocks[2].render_runs[0][2].fg.should eq 0x00FF00

    # Closing the comment early re-highlights the following blocks even
    # though the edit touched only block 0.
    doc.insert_text(8, " */")
    doc.blocks[0].user_state.should eq 0
    doc.blocks[1].user_state.should eq 0
    doc.blocks[1].render_runs[0][2].fg.should be_nil
  end

  it "detaches from a document, clearing its overlay, and stops updating" do
    doc, hl = digit_doc("1")
    doc.blocks[0].additional_formats.should_not be_nil
    hl.document = nil
    # BUGS13 T7: detach removes the highlighter's overlays and user states,
    # so the old document renders plain again.
    doc.blocks[0].additional_formats.should be_nil
    doc.insert_text(1, "2")
    # And no re-highlight happens after detach.
    doc.blocks[0].additional_formats.should be_nil
    doc.blocks[0].render_runs.size.should eq 1
  end

  it "renders the overlay through Widget::TextEdit" do
    s = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 20, height: 4)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 20, height: 4, content: "v 99"
    DigitHighlighter.new(te.document)
    s.repaint
    Attr.fg(s.lines[0][2].attr).should eq Attr.pack_color(0xFF0000)
    Attr.fg(s.lines[0][0].attr).should eq Attr.pack_color(-1)
  end
end
