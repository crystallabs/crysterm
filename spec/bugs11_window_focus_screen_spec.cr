require "./spec_helper"

include Crysterm

# Regression coverage for two BUGS11 findings:
#
#  #4 (src/window_focus.cr) `focus_pop` never blurred the popped widget when
#     the history emptied: the widget stayed in `WidgetState::Focused` and no
#     `Event::FocusOut` fired. It now mirrors `rewind_focus`'s empty-history branch
#     (`blur_state_reset` + `FocusOut` with a nil payload).
#
#  #5 (src/window.cr) `Window#screen=` tore down the old device but never
#     started input listening on a genuinely new device, so a moved window went
#     deaf. It now captures the listening state before teardown and re-`listen`s
#     on the new device, mirroring `Window#connect`.

private def bugs11_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def bugs11_device
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10)
end

describe "BUGS11 #4: focus_pop blurs the popped widget when the history empties" do
  it "resets the :focused state and emits Blur when popping the sole focused widget" do
    win = bugs11_window
    a = Widget::Box.new parent: win, left: 0, top: 0, width: 10, height: 1
    win.repaint

    win.focus a
    win.focused.should be(a)
    a.state.focused?.should be_true # precondition

    blur_payload = nil.as(Widget?)
    blurred = false
    a.on(Crysterm::Event::FocusOut) do |e|
      blurred = true
      blur_payload = e.next_focused
    end

    popped = win.focus_pop # only entry -> empty-history branch

    popped.should be(a)
    win.focused.should be_nil
    a.state.focused?.should be_false # was still :focused before the fix
    blurred.should be_true           # no Blur emitted before the fix
    blur_payload.should be_nil       # nil payload: no widget takes over focus
  end
end

describe "BUGS11 #5: Window#screen= starts input listening on a genuinely new device" do
  it "listens on the new device when the window was listening before the move" do
    app = Crysterm::Application.new
    dev_a = bugs11_device
    dev_b = bugs11_device
    w = Crysterm::Window.new(screen: dev_a, default_quit_keys: false)
    app.add w

    w.start_input                   # window is listening on its old device
    dev_a.listening?.should be_true # precondition

    w.screen = dev_b # move onto a fresh device (no sibling backs it)

    dev_b.listening?.should be_true # was deaf on the new device before the fix
  end
end
