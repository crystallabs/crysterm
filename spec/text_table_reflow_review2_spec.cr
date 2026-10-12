require "./spec_helper"

include Crysterm

private GFM2 = <<-MD
  | Key | What it does |
  | --- | --- |
  | F1 | Shows the description of the highlighted menu entry beside it until the next key |
  | F5 | Cycles the mouse modes |
  MD

describe TextUndoStack do
  it "keeps an edit block one step when a reflow inside it drops the history" do
    doc = TextDocument.new
    doc.set_markdown GFM2 + "\n\npara"
    doc.cursor(doc.size).insert_text("!")
    doc.edit do
      doc.cursor(doc.size).insert_text("?")
      doc.text_width = 30
      doc.cursor(doc.size - 6).insert_text("X")
      doc.cursor(doc.size).insert_text("\nY")
    end
    after = doc.to_plain_text
    doc.undo.should be_true
    text = doc.to_plain_text
    text.should_not contain "Y"
    text.should_not contain "X"
    text.should end_with "?"
    doc.undo.should be_false
    doc.modified?.should be_true
    doc.redo.should be_true
    doc.to_plain_text.should eq after
  end
end
