require "./spec_helper"

include Crysterm

# TextFrame nesting (TEXTEDIT.md follow-up; Qt QTextFrame): child frames as
# identity-keyed views over `TextBlockFormat#frame_formats` paths, created
# via `TextCursor#insert_frame`, navigated via `child_frames`/`parent_frame`
# and `TextDocument#frame_at`. Pure model.

private def framed_doc
  doc = TextDocument.new("before\ninside\nafter")
  c = TextCursor.new(doc)
  c.set_position(7) # "inside"
  frame = c.insert_frame(TextFrameFormat.new(border: true))
  {doc, frame}
end

describe Crysterm::TextFrame do
  it "root frame owns every block" do
    doc = TextDocument.new("a\nb")
    doc.root_frame.root?.should be_true
    doc.root_frame.blocks.size.should eq 2
    doc.root_frame.first_position.should eq 0
    doc.root_frame.last_position.should eq doc.size
  end

  it "insert_frame nests the current block in a new child frame" do
    doc, frame = framed_doc
    frame.root?.should be_false
    frame.blocks.size.should eq 1
    frame.blocks[0].text.should eq "inside"
    frame.first_position.should eq 7
    frame.last_position.should eq 13
    doc.blocks[0].block_format.frame_formats.should be_nil
    doc.blocks[1].block_format.frame_formats.not_nil!.size.should eq 1
  end

  it "frame_at and current_frame find the innermost frame" do
    doc, frame = framed_doc
    doc.frame_at(8).frame_format.should be frame.frame_format
    doc.frame_at(0).root?.should be_true
    c = TextCursor.new(doc, 8)
    c.current_frame.frame_format.should be frame.frame_format
    c.set_position(0)
    c.current_frame.root?.should be_true
  end

  it "navigates child_frames and parent_frame" do
    doc, frame = framed_doc
    kids = doc.root_frame.child_frames
    kids.size.should eq 1
    kids[0].frame_format.should be frame.frame_format
    frame.parent_frame.not_nil!.root?.should be_true

    # Nest another frame inside.
    c = TextCursor.new(doc, 8)
    inner = c.insert_frame(TextFrameFormat.new(margin: 1))
    inner.parent_frame.not_nil!.frame_format.should be frame.frame_format
    frame.child_frames.size.should eq 1
    frame.child_frames[0].frame_format.should be inner.frame_format
    # The block belongs to both frames.
    frame.member?(doc.blocks[1]).should be_true
    inner.member?(doc.blocks[1]).should be_true
    doc.frame_at(8).frame_format.should be inner.frame_format
  end

  it "selection insert_frame spans all selected blocks with one instance" do
    doc = TextDocument.new("a\nb\nc")
    c = TextCursor.new(doc)
    c.set_position(0)
    c.set_position(4, :keep_anchor) # "a\nb\nc" — blocks 0..2
    frame = c.insert_frame(TextFrameFormat.new(border: true))
    frame.blocks.size.should eq 3
    f0 = doc.blocks[0].block_format.frame_formats.not_nil![0]
    doc.blocks[1].block_format.frame_formats.not_nil![0].should be f0
  end

  it "keeps membership across a block split (Enter inside the frame)" do
    doc, frame = framed_doc
    doc.insert_text(10, "\n") # split "inside"
    frame.blocks.size.should eq 2
  end

  it "restores membership on undo" do
    doc, frame = framed_doc
    doc.undo.should be_true # undo the frame's block-format change
    frame.blocks.size.should eq 0
    frame.first_position.should be_nil
    doc.redo.should be_true
    frame.blocks.size.should eq 1
  end
end
