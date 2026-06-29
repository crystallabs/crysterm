require "./spec_helper"

include Crysterm

private def pc_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "Pine::Compose focus" do
  # The composer's header fields are focusable in order, so the screen's Tab
  # navigation (which Enter is re-emitted as in the demo) cycles through them and
  # then into the body.
  it "advances focus through the fields via focus_next (Tab)" do
    s = pc_screen
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"

    compose.focus_first
    s.focused.should eq compose.fields["to"]

    s.focus_next
    s.focused.should eq compose.fields["cc"]
  end

  it "reaches the body after the last header field" do
    s = pc_screen
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"

    compose.fields["subject"].focus
    s.focus_next
    s.focused.should eq compose.body
  end

  # Enter in a header field finishes the read WITHOUT rewinding focus, and the
  # field's Submit advances to the next field (the widget emits a Tab). This is
  # what makes Enter behave like Tab without the field "submitting" back to the
  # opener.
  it "advances to the next field on Enter (Submit), without rewinding" do
    s = pc_screen
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"

    compose.focus_field "to"
    compose.fields["to"].submit # the Enter/done path
    s.focused.should eq compose.fields["cc"]
  end

  it "advances from the last header field into the body on Enter" do
    s = pc_screen
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"

    compose.fields["subject"].focus
    compose.fields["subject"].submit
    s.focused.should eq compose.body
  end

  it "does not rewind focus on a header field (rewind_on_done is off)" do
    s = pc_screen
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"
    compose.fields["to"].rewind_on_done?.should be_false
  end

  # Up/Down move between fields (history is disabled on the form's LineEdits).
  it "Down/Up move between header fields" do
    s = pc_screen
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"
    compose.focus_field "to"
    compose.fields["to"].emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', Tput::Key::Down)
    s.focused.should eq compose.fields["cc"]
    compose.fields["cc"].emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', Tput::Key::Up)
    s.focused.should eq compose.fields["to"]
  end

  it "Up at the top of the body returns to the previous field" do
    s = pc_screen
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"
    compose.body.focus
    compose.body.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', Tput::Key::Up)
    s.focused.should eq compose.fields["subject"]
  end

  # `header_field?` distinguishes the header inputs (where Enter should advance)
  # from the body (where Enter inserts a newline).
  it "identifies header fields but not the body" do
    s = pc_screen
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"

    compose.header_field?(compose.fields["to"]).should be_true
    compose.header_field?(compose.fields["subject"]).should be_true
    compose.header_field?(compose.body).should be_false
  end

  # `focus_field` lands on a named header field (used to return to the Attchmnt
  # field after picking a file), falling back to the first field otherwise.
  it "focuses a named field via #focus_field" do
    s = pc_screen
    compose = Crysterm::Widget::Pine::Compose.new parent: s, top: 0, bottom: 0, left: 0, width: "100%"

    compose.focus_field "attchmnt"
    s.focused.should eq compose.fields["attchmnt"]

    compose.focus_field "nope"
    s.focused.should eq compose.fields.first_value
  end
end
