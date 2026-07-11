require "./spec_helper"

include Crysterm

# BUGS14 T2/T6 — undo-stack clean sealing and empty `{escape}{/escape}` parsing.

describe "BUGS14 T2 mark_clean seals so the next contiguous edit marks the document modified" do
  it "reports modified after a contiguous keystroke following mark_clean" do
    doc = Crysterm::TextDocument.new
    c = Crysterm::TextCursor.new(doc)
    c.insert_text("a")
    doc.modified = false
    doc.modified?.should be_false
    c.insert_text("b") # contiguous, at position 1
    doc.to_plain_text.should eq "ab"
    doc.modified?.should be_true # was false before the seal_last fix
  end

  it "stays clean when mark_clean is followed by no edits" do
    doc = Crysterm::TextDocument.new
    c = Crysterm::TextCursor.new(doc)
    c.insert_text("a")
    doc.modified = false
    doc.modified?.should be_false
  end
end

describe "BUGS14 T6 empty {escape}{/escape} pair parses away without leaking" do
  it "parses \"a{escape}{/escape}b\" to \"ab\" and keeps later tags working" do
    doc = Crysterm::TextDocument.from_tags("a{escape}{/escape}b")
    doc.to_plain_text.should eq "ab" # was "a{/escape}b" before the *? fix

    # Tags after an empty escape still parse.
    doc2 = Crysterm::TextDocument.from_tags("a{escape}{/escape}{bold}c{/bold}")
    doc2.to_plain_text.should eq "ac"
    doc2.blocks[0].fragments.find! { |f| f.text == "c" }.format.bold?.should be_true
  end
end
