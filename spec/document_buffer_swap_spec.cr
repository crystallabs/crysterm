require "./spec_helper"

# `DocumentBuffer#document=` (Qt `setDocument`) reports the caret's rewind
# when it happens, not at the next keystroke.
describe "DocumentBuffer#document=" do
  it "reports the caret moved to the start, after DocumentChanged" do
    edit = Crysterm::Widget::PlainTextEdit.new content: "hello world"
    edit.cursor_position = 5
    edit.text_cursor = Crysterm::TextCursor.new(edit.document, 5) # reported once
    events = [] of String
    edit.on(Crysterm::Event::DocumentChanged) { events << "document" }
    edit.on(Crysterm::Event::CursorPositionChanged) { |e| events << "caret #{e.position}" }
    edit.document = Crysterm::TextDocument.new("other")
    events.should eq ["document", "caret 0"]
    edit.cursor_position.should eq 0
  end
end
