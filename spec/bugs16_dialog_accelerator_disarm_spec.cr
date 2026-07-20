require "./spec_helper"

include Crysterm

# B16-40: Dialog#open installs a window-level Enter/Escape accelerator, but the
# close funnel (#done) only hides the dialog — it never uninstalls it. With the
# base `dialog_keys_active?` returning true unconditionally, a dialog closed via
# Enter/Escape stayed armed on the window: every later unconsumed Enter re-ran
# accept -> done(Accepted), re-emitting Accepted/Finished on the closed dialog
# and stealing the key from the rest of the UI. The base accelerator must gate on
# visibility, like Wizard already does.

# The minimal concrete dialog: the base class is abstract, so base-level
# accelerator behavior needs a subclass that adds nothing.
private class BareDialog < Crysterm::Widget::Dialog
end

private def bd_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    default_quit_keys: false)
end

describe "Dialog Enter/Escape accelerator disarms on close (B16-40)" do
  it "does not re-emit Accepted/Finished on a later Enter after the dialog closed" do
    w = bd_window
    d = BareDialog.new parent: w, width: 20, height: 5
    log = [] of String
    d.on(Crysterm::Event::Accepted) { log << "accepted" }
    d.on(Crysterm::Event::Finished) { |e| log << "finished=#{e.result}" }

    d.open
    # First Enter closes the dialog affirmatively.
    w.emit Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter)
    log.should eq ["accepted", "finished=1"]
    d.visible?.should be_false

    # A later Enter must NOT reach the now-hidden dialog: no second outcome pair.
    w.emit Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter)
    log.should eq ["accepted", "finished=1"]
  end

  it "leaves a later Enter unaccepted, so it reaches the rest of the UI" do
    w = bd_window
    d = BareDialog.new parent: w, width: 20, height: 5

    d.open
    w.emit Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter) # closes it

    # The closed dialog must not swallow the key any more.
    e = Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter)
    w.emit e
    e.accepted?.should be_false
  end

  it "re-arms on reopen: the accelerator works again after a second #open" do
    w = bd_window
    d = BareDialog.new parent: w, width: 20, height: 5
    log = [] of String
    d.on(Crysterm::Event::Finished) { |e| log << "finished=#{e.result}" }

    d.open
    w.emit Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Escape)
    log.should eq ["finished=0"]

    d.open
    w.emit Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter)
    log.should eq ["finished=0", "finished=1"]
  end
end
