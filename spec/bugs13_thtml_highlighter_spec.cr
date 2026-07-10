require "./spec_helper"

include Crysterm

# BUGS13 T7/T29 — `SyntaxHighlighter`: clean detach (no stale overlays or
# user states) and the removal-at-block-boundary rehighlight window.

# Highlights every digit run (same as syntax_highlighter_spec).
private class T13DigitHighlighter < Crysterm::SyntaxHighlighter
  def highlight_block(text)
    text.scan(/\d+/) do |md|
      set_format(md.begin(0), md[0].size, 0xFF0000)
    end
  end
end

# Multi-line `/* … */` comments: state 1 = "inside a comment" (same protocol
# as syntax_highlighter_spec's CommentHighlighter).
private class T13CommentHighlighter < Crysterm::SyntaxHighlighter
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

describe "BUGS13 T7 detaching a highlighter cleans the old document" do
  it "clears overlays and user states and pokes a repaint" do
    doc = Crysterm::TextDocument.new("a 12\nplain")
    hl = T13DigitHighlighter.new(doc)
    doc.blocks[0].additional_formats.should_not be_nil
    doc.blocks[0].user_state = 5 # a stored multi-line state

    pokes = 0
    doc.on(Crysterm::Event::ContentsChange) { |_e| pokes += 1 }
    hl.document = nil

    hl.document.should be_nil
    doc.blocks.each do |b|
      b.additional_formats.should be_nil
      b.user_state.should eq -1
    end
    pokes.should eq 1
  end

  it "cleans the old document when switching to a new one" do
    doc1 = Crysterm::TextDocument.new("1")
    doc2 = Crysterm::TextDocument.new("2")
    hl = T13DigitHighlighter.new(doc1)
    doc1.blocks[0].additional_formats.should_not be_nil

    hl.document = doc2
    doc1.blocks[0].additional_formats.should be_nil
    doc2.blocks[0].additional_formats.should_not be_nil
  end

  it "does not poke when there was nothing to clean" do
    doc = Crysterm::TextDocument.new("plain")
    hl = T13DigitHighlighter.new(doc)
    pokes = 0
    doc.on(Crysterm::Event::ContentsChange) { |_e| pokes += 1 }
    hl.document = nil
    pokes.should eq 0
  end
end

describe "BUGS13 T29 removal ending at a block boundary rehighlights the follower" do
  it "re-opens a multi-line comment when its closer line is deleted" do
    doc = Crysterm::TextDocument.new("start\n/*\nmid\n*/\nafter")
    T13CommentHighlighter.new(doc)
    doc.blocks[4].text.should eq "after"
    doc.blocks[4].additional_formats.should be_nil # outside the comment
    doc.blocks[4].user_state.should eq 0

    # Delete the closing "*/" line (its preceding separator + both chars):
    # the removal ends exactly at "after"'s block start, added == 0.
    doc.remove(12, 3)
    doc.to_plain_text.should eq "start\n/*\nmid\nafter"

    after = doc.blocks[3]
    after.text.should eq "after"
    after.user_state.should eq 1               # now inside the open comment
    after.additional_formats.should_not be_nil # and painted as such
  end

  it "undo of an insert ending at a block boundary rehighlights too" do
    doc = Crysterm::TextDocument.new("/*\nx\nrest")
    T13CommentHighlighter.new(doc)
    doc.blocks[2].user_state.should eq 1

    # Insert a closing line after "x", then undo it: the undo is a removal
    # starting at "x"'s block end and ending exactly at "rest"'s block start.
    doc.insert_text(4, "\n*/")
    doc.to_plain_text.should eq "/*\nx\n*/\nrest"
    doc.blocks[3].user_state.should eq 0

    doc.undo.should be_true
    doc.to_plain_text.should eq "/*\nx\nrest"
    doc.blocks[2].user_state.should eq 1
    doc.blocks[2].additional_formats.should_not be_nil
  end
end
