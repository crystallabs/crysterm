require "./spec_helper"

include Crysterm

# `LinePrompt#prompt(completer:)`: a question completing with its own
# completer, the prompt's `#completer` left for the others.
describe "LinePrompt#prompt completer:" do
  it "completes one question with its own completer and the next with the prompt's" do
    s = headless_screen(40, 5)
    editor = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 3
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    editor.focus
    s.repaint
    cl = bar.line_prompt
    cl.completer = ->(text : String) { ["file.md"].select(&.starts_with?(text)) }
    field = cl.field
    tab = Event::KeyPress.new '\0', Tput::Key::Tab

    bar.prompt(":", "sa", completer: ->(text : String) { ["save", "save-as"].select(&.starts_with?(text)) }) { }
    field.emit Event::KeyPress, tab
    field.value.should eq "save"
    cl.cancel

    bar.prompt("Open: ", "fi") { }
    field.emit Event::KeyPress, tab
    field.value.should eq "file.md"
    cl.cancel

    bar.prompt("/", "fi", completer: nil) { }
    field.emit Event::KeyPress, tab
    field.value.should eq "fi"
    cl.cancel
  end
end
