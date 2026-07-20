require "./spec_helper"

include Crysterm

# B17-29: two different `SyntaxHighlighter`s attached to one `TextDocument`
# used to re-trigger each other in unbounded synchronous recursion (each
# other's block-0 overlay looked like a change, poking a zero-length
# `ContentsChanged` that re-entered the sibling highlighter forever). The fix
# ignores the zero-length repaint pokes in `on_contents_change`, so attachment
# and rehighlight terminate. The highlighters still overwrite each other's
# single `additional_formats` slot — an inherent limitation, not recursion.

# Highlights every digit run (mirrors the double in syntax_highlighter_spec).
private class DigitHighlighter < Crysterm::SyntaxHighlighter
  def highlight_block(text)
    text.scan(/\d+/) do |md|
      set_format(md.begin(0), md[0].size, 0xFF0000)
    end
  end
end

# Highlights every lowercase-letter run — a different overlay from the digits.
private class LetterHighlighter < Crysterm::SyntaxHighlighter
  def highlight_block(text)
    text.scan(/[a-z]+/) do |md|
      set_format(md.begin(0), md[0].size, 0x00FF00)
    end
  end
end

describe Crysterm::SyntaxHighlighter do
  it "does not recurse when two different highlighters share one document" do
    doc = Crysterm::TextDocument.new("x 1")
    # Both attachments (each runs a whole-document rehighlight) must terminate;
    # before the fix the second constructor overflowed the stack.
    DigitHighlighter.new(doc)
    LetterHighlighter.new(doc)
    doc.to_plain_text.should eq "x 1"

    # A subsequent real edit still triggers rehighlighting (the last-attached
    # highlighter re-runs and re-establishes its overlay).
    doc.insert_text(3, " yy")
    doc.to_plain_text.should eq "x 1 yy"
    runs = doc.blocks[0].render_runs
    runs.any? { |r| r[2].fg == 0x00FF00 }.should be_true
  end
end
