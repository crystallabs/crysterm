require "./spec_helper"

include Crysterm

# BUGS13 T9/T10 — `TextDocument`/`TextUndoStack`: RemoveCommand coalescing
# must not mutate the fragment already returned to the caller, and
# `raw_insert_fragment` at a block start must carry the fragment head's
# block format (list/table membership).

describe "BUGS13 T9 forward-delete coalescing leaves the returned fragment alone" do
  it "does not grow the fragment TextDocument#remove returned" do
    doc = Crysterm::TextDocument.new("abcdef")
    first = doc.remove(1, 1) # "b"
    first.to_plain_text.should eq "b"
    doc.remove(1, 1)                  # "c" — coalesces with the previous command at the same pos
    doc.remove(1, 1)                  # "d"
    first.to_plain_text.should eq "b" # was "bcd" before the fix

    # The coalesced command still undoes the whole run.
    doc.undo.should be_true
    doc.to_plain_text.should eq "abcdef"
  end
end

describe "BUGS13 T10 insert_fragment at a block start keeps the head block's membership" do
  it "pastes a two-item list with both blocks as members" do
    doc = Crysterm::TextDocument.new("x")
    frag = Crysterm::TextDocumentFragment.from_tags("{!block;list-disc}a\n{!block;list-disc}b")
    frag.blocks[0].block_format.list_format.should_not be_nil

    doc.insert_fragment(0, frag)
    doc.to_plain_text.should eq "a\nbx"
    lf0 = doc.blocks[0].block_format.list_format
    lf1 = doc.blocks[1].block_format.list_format
    lf0.should_not be_nil # was nil (membership dropped) before the fix
    lf1.should_not be_nil
    lf0.try(&.same?(lf1)).should be_true
  end

  it "restores the insertion-point block's format on undo" do
    doc = Crysterm::TextDocument.new("x")
    doc.blocks[0].block_format = TextBlockFormat.new(heading_level: 2)
    frag = Crysterm::TextDocumentFragment.from_tags("{!block;list-disc}a\n{!block;list-disc}b")

    doc.insert_fragment(0, frag)
    doc.blocks[0].block_format.list_format.should_not be_nil

    doc.undo.should be_true
    doc.to_plain_text.should eq "x"
    doc.blocks[0].block_format.list_format.should be_nil
    doc.blocks[0].block_format.heading_level.should eq 2

    # And redo re-applies the membership.
    doc.redo.should be_true
    doc.blocks[0].block_format.list_format.should_not be_nil
  end

  it "keeps the surrounding block's format for a mid-block insertion" do
    doc = Crysterm::TextDocument.new("xy")
    doc.blocks[0].block_format = TextBlockFormat.new(heading_level: 2)
    frag = Crysterm::TextDocumentFragment.from_tags("{!block;list-disc}a\n{!block;list-disc}b")

    doc.insert_fragment(1, frag)
    doc.to_plain_text.should eq "xa\nby"
    doc.blocks[0].block_format.heading_level.should eq 2
    doc.blocks[0].block_format.list_format.should be_nil
  end
end
