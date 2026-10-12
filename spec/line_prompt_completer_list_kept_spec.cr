require "./spec_helper"

include Crysterm

# A completer may answer with a list it keeps (a fixed set of names): the
# prompt reads it but must not empty it when the completion run ends.
describe "LinePrompt completion run" do
  it "leaves the completer's own list as it was" do
    s = headless_screen(40, 5)
    bar = Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: "100%", height: 1
    s.repaint
    cl = bar.line_prompt
    names = ["save", "save-as"]
    field = cl.field
    tab = Event::KeyPress.new '\0', Tput::Key::Tab

    bar.prompt(":", "", completer: ->(_text : String) { names }) { }
    field.emit Event::KeyPress, tab
    field.value.should eq "save"
    # Any other key ends the run.
    field.emit Event::KeyPress, Event::KeyPress.new('x')
    names.should eq ["save", "save-as"]
    cl.cancel
  end
end
