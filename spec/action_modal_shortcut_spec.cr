require "./spec_helper"

include Crysterm

# An action's shortcut stands down while a modal dialog is up, unless the
# action is the dialog's own (Qt's shortcut map and `activeModalWidget`).
describe "Action shortcuts under a modal dialog" do
  it "fire outside a modal dialog only while none is up" do
    s = headless_screen(40, 10)
    box = Widget::Box.new parent: s, width: 40, height: 10
    fired = [] of String
    outer = Action.new "Outer", box, shortcut: Tput::Key::F1
    outer.on(Event::Triggered) { fired << "outer" }
    dialog = Widget::MessageBox.new parent: s, width: 20, height: 5
    inner = Action.new "Inner", dialog, shortcut: Tput::Key::F2
    inner.on(Event::Triggered) { fired << "inner" }
    s.repaint

    s.emit Event::KeyPress, Event::KeyPress.new('\0', Tput::Key::F1)
    fired.should eq ["outer"]

    dialog.open("Sure?") { |_ok| }
    s.active_modal_widget.should be dialog
    s.emit Event::KeyPress, Event::KeyPress.new('\0', Tput::Key::F1)
    s.emit Event::KeyPress, Event::KeyPress.new('\0', Tput::Key::F2)
    fired.should eq ["outer", "inner"]

    dialog.done Widget::Dialog::Code::Rejected
    s.active_modal_widget.should be_nil
    s.emit Event::KeyPress, Event::KeyPress.new('\0', Tput::Key::F1)
    fired.should eq ["outer", "inner", "outer"]
  end
end
