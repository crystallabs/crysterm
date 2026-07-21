require "./spec_helper"

include Crysterm

# Regression spec for BUGS16 B16-39 (src/widget/question.cr, src/widget/message.cr).
#
# `Question#ask` installs a window-level `KeyPress` handler that treats
# Enter/Escape/'q'/'y'/'n' as answers, but never called `e.accept` on any of
# them. `Application#route_input` (and `Application.exec_all`) apply the
# default quit keys as a *fallback*, only when the `KeyPress` comes back
# un-accepted: since answering a dialog with 'q' left the event un-accepted,
# the same keystroke that correctly answered the dialog also fell through to
# the app-global quit fallback and tore down every window. Same defect in
# `ask_choices`'s Left/Right/Escape arms and in `Message#display`'s
# no-timeout any-key-dismiss handler.

private def b16_window(w = 40, h = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "BUGS16 B16-39: Question#ask accepts its handled keys" do
  it "'q' answers No and does not reach the default-quit-key fallback" do
    w = b16_window
    q = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    answer = nil.as(Bool?)
    q.ask("Sure?") { |data| answer = data }

    e = Crysterm::Event::KeyPress.new 'q'
    w.emit e

    answer.should be_false
    e.accepted?.should be_true
  end

  it "'y' answers Yes and accepts the key" do
    w = b16_window
    q = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    answer = nil.as(Bool?)
    q.ask("Sure?") { |data| answer = data }

    e = Crysterm::Event::KeyPress.new 'y'
    w.emit e

    answer.should be_true
    e.accepted?.should be_true
  end

  it "'n' answers No and accepts the key" do
    w = b16_window
    q = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    answer = nil.as(Bool?)
    q.ask("Sure?") { |data| answer = data }

    e = Crysterm::Event::KeyPress.new 'n'
    w.emit e

    answer.should be_false
    e.accepted?.should be_true
  end

  it "Enter/Escape also accept the key" do
    w = b16_window
    q = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    q.ask("Sure?") { }
    e1 = Crysterm::Event::KeyPress.new '\r', ::Tput::Key::Enter
    w.emit e1
    e1.accepted?.should be_true

    q2 = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    q2.ask("Sure?") { }
    e2 = Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Escape
    w.emit e2
    e2.accepted?.should be_true
  end

  it "answering 'q' does not let Application.exec_all's quit fallback destroy the window" do
    w = b16_window
    q = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    answer = nil.as(Bool?)
    # Installed before `exec_all` runs, exactly like a real app builds its UI
    # (dialogs and all) before entering the event loop.
    q.ask("Sure?") { |data| answer = data }

    spawn { Application.exec_all [w] }
    sleep 20.milliseconds # let exec_all install its own quit-key handler

    w.emit Crysterm::Event::KeyPress.new 'q'
    sleep 30.milliseconds

    answer.should be_false
    w.destroyed?.should be_false
    w.destroy
  end

  it "ask_choices accepts Left/Right/Escape so they don't fall through" do
    w = b16_window
    q = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    picked = :unset.as(Symbol | Int32?)
    q.ask_choices("Pick", choices: ["A", "B", "C"]) { |idx| picked = idx }

    e_right = Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Right
    w.emit e_right
    e_right.accepted?.should be_true

    e_left = Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Left
    w.emit e_left
    e_left.accepted?.should be_true

    e_esc = Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Escape
    w.emit e_esc
    e_esc.accepted?.should be_true
    picked.should be_nil
  end
end

describe "BUGS16 B16-39: Message#display accepts its dismiss key" do
  it "any key dismisses the message and is accepted, not left to quit the app" do
    w = b16_window
    m = Widget::Message.new parent: w, top: 0, left: 0, width: 40, height: 5
    called = false
    m.display("hi", Time::Span.zero) { called = true }

    e = Crysterm::Event::KeyPress.new 'q'
    w.emit e

    called.should be_true
    e.accepted?.should be_true
  end
end
