require "./spec_helper"

include Crysterm

private def press(char : Char) : Event::KeyPress
  Event::KeyPress.new char
end

private def press(key : Tput::Key) : Event::KeyPress
  Event::KeyPress.new '\0', key
end

# `Application.quit_gesture?` decides the default `q`/`Ctrl-Q` quit for both
# `#route_input` and `.exec_all`. A reading widget grabs the keyboard for the
# duration of its read, which must not disable the hard-exit chord nor the
# keys the app put on the always-propagate lists for exactly that purpose.
describe "Application.quit_gesture? under a keyboard grab" do
  it "quits on an unconsumed quit key without a grab, never on a consumed one" do
    w = headless_screen(40, 10)
    Application.quit_gesture?(w, press('q')).should be_true
    Application.quit_gesture?(w, press(Tput::Key::CtrlQ)).should be_true
    Application.quit_gesture?(w, press('x')).should be_false
    e = press('q')
    e.accept
    Application.quit_gesture?(w, e).should be_false
  end

  it "lets Ctrl-Q, but not a plain q, through a grab" do
    w = headless_screen(40, 10)
    w.grab_keys = true
    Application.quit_gesture?(w, press('q')).should be_false
    Application.quit_gesture?(w, press(Tput::Key::CtrlQ)).should be_true
    e = press(Tput::Key::CtrlQ)
    e.accept
    Application.quit_gesture?(w, e).should be_false
  end

  it "lets an always-propagated quit key through a grab" do
    w = headless_screen(40, 10)
    w.grab_keys = true
    w.always_propagated_chars << 'q'
    w.always_propagated?(press('q')).should be_true
    w.always_propagated?(press('x')).should be_false
    Application.quit_gesture?(w, press('q')).should be_true
    e = press('q')
    e.accept
    Application.quit_gesture?(w, e).should be_false
  end
end

describe "Screen.default_input" do
  it "is an in-memory IO when headless" do
    was = Config.screen_headless
    begin
      Config.set "screen.headless", Headless::Always
      Screen.default_input.should be_a IO::Memory
    ensure
      Config.set "screen.headless", was
    end
  end

  it "names a terminal's device only for a terminal" do
    Screen.terminal_path(IO::Memory.new).should be_nil
    io = IO::FileDescriptor.new(STDIN.fd, close_on_finalize: false)
    if io.tty?
      Screen.terminal_path(io).not_nil!.should start_with "/dev/"
    else
      Screen.terminal_path(io).should be_nil
    end
  end
end
