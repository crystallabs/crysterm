require "./spec_helper"

include Crysterm

# `Event::KeyPress.parse` — human-readable key labels (as shown in command
# bars like `Pine::KeyMenu`) turned into replayable keypresses.
describe "Event::KeyPress.parse" do
  it "parses printable single characters" do
    kp = Event::KeyPress.parse("s").not_nil!
    kp.char.should eq 's'
    kp.key.should be_nil
  end

  it "parses caret chords to Ctrl keys" do
    Event::KeyPress.parse("^X").not_nil!.key.should eq Tput::Key::CtrlX
    Event::KeyPress.parse("^g").not_nil!.key.should eq Tput::Key::CtrlG
  end

  it "parses conventional key names" do
    Event::KeyPress.parse("Spc").not_nil!.char.should eq ' '
    Event::KeyPress.parse("Enter").not_nil!.key.should eq Tput::Key::Enter
    Event::KeyPress.parse("Dn").not_nil!.key.should eq Tput::Key::Down
    Event::KeyPress.parse("PgDn").not_nil!.key.should eq Tput::Key::PageDown
    Event::KeyPress.parse("F5").not_nil!.key.should eq Tput::Key::F5
  end

  it "returns nil for unknown labels" do
    Event::KeyPress.parse("NoSuch").should be_nil
    Event::KeyPress.parse("").should be_nil
  end
end
