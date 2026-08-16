require "./spec_helper"

include Crysterm

# BUGS13 T9/T10 — `TextDocument`/`TextUndoStack`: RemoveCommand coalescing
# must not mutate the fragment already returned to the caller, and
# `raw_insert_fragment` at a block start must carry the fragment head's
# block format (list/table membership).

describe "BUGS13 T9 forward-delete coalescing leaves caller-held fragments alone" do
  it "does not grow a fragment snapshotted before the coalescing run" do
    doc = Crysterm::TextDocument.new("abcdef")
    first = doc.cursor(1, 2).selection # snapshot of "b"
    first.to_plain_text.should eq "b"
    doc.cursor(1, 2).remove_selected_text # "b"
    doc.cursor(1, 2).remove_selected_text # "c" — coalesces with the previous command at the same pos
    doc.cursor(1, 2).remove_selected_text # "d"
    first.to_plain_text.should eq "b"     # must not grow to "bcd"

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

    doc.cursor(0).insert_fragment(frag)
    doc.to_plain_text.should eq "a\nbx"
    lf0 = doc.blocks[0].block_format.list_format
    lf1 = doc.blocks[1].block_format.list_format
    lf0.should_not be_nil # membership must not be dropped
    lf1.should_not be_nil
    lf0.try(&.same?(lf1)).should be_true
  end

  it "restores the insertion-point block's format on undo" do
    doc = Crysterm::TextDocument.new("x")
    doc.cursor(0, 0).set_block_format(TextBlockFormat.new(heading_level: 2))
    frag = Crysterm::TextDocumentFragment.from_tags("{!block;list-disc}a\n{!block;list-disc}b")

    doc.cursor(0).insert_fragment(frag)
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
    doc.cursor(0, 0).set_block_format(TextBlockFormat.new(heading_level: 2))
    frag = Crysterm::TextDocumentFragment.from_tags("{!block;list-disc}a\n{!block;list-disc}b")

    doc.cursor(1).insert_fragment(frag)
    doc.to_plain_text.should eq "xa\nby"
    doc.blocks[0].block_format.heading_level.should eq 2
    doc.blocks[0].block_format.list_format.should be_nil
  end
end
