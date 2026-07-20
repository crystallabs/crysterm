require "./spec_helper"

include Crysterm

# Regression spec for BUGS17 B17-17 (src/widget/question.cr).
#
# `Question#ask`/`#ask_choices` install a window-level `KeyPress` accelerator.
# Before the fix these were raw `window.on` handlers removed only inside the
# local `finish` proc, and `Question` had no `#destroy` override — so a dialog
# destroyed while an answer was still pending left its accelerator on the live
# window holding the dead dialog. A later unconsumed Enter/Escape/'q'/'y'/'n'
# anywhere in the app was then swallowed (permanently, once the done-latch
# tripped) and `finish` ran against the destroyed widget, with
# `window.restore_focus` raising `NilAssertionError` on the way.
#
# The fix routes both accelerators through a `Crysterm::Subscription` stored in
# an ivar and adds a `Question#destroy` override that drops the subscription,
# runs the OK/Cancel teardown while the window is still valid, and nils the
# pending callbacks so nothing can fire post-destroy.

private def b17_window(w = 40, h = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "BUGS17 B17-17: Question#ask tears down its accelerator on destroy" do
  it "destroy while an ask is pending leaves no stale window handler" do
    w = b17_window
    q = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    answer = :unset.as(Symbol | Bool)
    q.ask("Delete file?") { |yes| answer = yes }

    q.destroy

    # A later 'q' (the default quit key) must not be swallowed by the stale
    # accelerator, and must not run the confirmation callback on the dead dialog.
    e = Crysterm::Event::KeyPress.new 'q'
    w.emit e # must not raise out of the input path
    answer.should eq(:unset)
    e.accepted?.should be_false

    # And Enter is likewise no longer captured.
    e2 = Crysterm::Event::KeyPress.new '\r', ::Tput::Key::Enter
    w.emit e2
    e2.accepted?.should be_false
  end

  it "does not permanently swallow keys on the window after destroy" do
    w = b17_window
    q = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    q.ask("Sure?") { }
    q.destroy

    # Emit a run of keys the buggy latch would have accepted forever.
    ['q', 'y', 'n'].each do |c|
      e = Crysterm::Event::KeyPress.new c
      w.emit e
      e.accepted?.should be_false
    end

    esc = Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Escape
    w.emit esc
    esc.accepted?.should be_false
  end

  it "a fresh ask on a new dialog still answers normally after an earlier one was destroyed" do
    w = b17_window
    stale = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    stale.ask("First?") { }
    stale.destroy

    q = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    answer = :unset.as(Symbol | Bool)
    q.ask("Second?") { |yes| answer = yes }

    e = Crysterm::Event::KeyPress.new 'y'
    w.emit e
    answer.should be_true
    e.accepted?.should be_true
  end

  it "destroy after a normal answer is a no-op (idempotent, does not raise)" do
    w = b17_window
    q = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    answer = :unset.as(Symbol | Bool)
    q.ask("Sure?") { |yes| answer = yes }

    w.emit Crysterm::Event::KeyPress.new 'y'
    answer.should be_true

    q.destroy # must not raise, must not re-fire the callback
    answer.should be_true

    e = Crysterm::Event::KeyPress.new 'q'
    w.emit e
    e.accepted?.should be_false
  end
end

describe "BUGS17 B17-17: Question#ask_choices tears down its accelerator on destroy" do
  it "destroy while an ask_choices is pending leaves no stale window handler" do
    w = b17_window
    q = Widget::Question.new parent: w, top: 0, left: 0, width: 40, height: 8
    picked = :unset.as(Symbol | Int32 | Nil)
    q.ask_choices("Pick", choices: ["A", "B", "C"]) { |idx| picked = idx }

    q.destroy

    # Escape used to be re-accepted (and re-raise) on every press; the choice
    # navigation keys likewise must no longer be captured.
    esc = Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Escape
    w.emit esc # must not raise
    picked.should eq(:unset)
    esc.accepted?.should be_false

    e_left = Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Left
    w.emit e_left
    e_left.accepted?.should be_false

    e_right = Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Right
    w.emit e_right
    e_right.accepted?.should be_false
  end
end
