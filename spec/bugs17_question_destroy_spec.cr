require "./spec_helper"

include Crysterm

# Regression spec for BUGS17 B17-17 (src/widget/question.cr).
#
# `MessageBox#open`'s question forms install a window-level `KeyPress` accelerator.
# As raw `window.on` handlers removed only inside the local `finish` proc (and
# with no `MessageBox#destroy` override), a dialog destroyed while an answer was
# still pending left its accelerator on the live window holding the dead
# dialog: a later unconsumed Enter/Escape/'q'/'y'/'n' anywhere in the app was
# swallowed (permanently, once the done-latch tripped) and `finish` ran
# against the destroyed widget, with `window.restore_focus` raising
# `NilAssertionError` on the way.
#
# Both accelerators must route through a `Crysterm::Subscription` stored in an
# ivar, and a `MessageBox#destroy` override must drop the subscription, run the
# OK/Cancel teardown while the window is still valid, and nil the pending
# callbacks so nothing can fire post-destroy.

describe "BUGS17 B17-17: MessageBox#open tears down its accelerator on destroy" do
  it "destroy while an ask is pending leaves no stale window handler" do
    w = headless_screen(40, 10, default_quit_keys: true)
    q = Widget::MessageBox.new parent: w, top: 0, left: 0, width: 40, height: 8
    answer = :unset.as(Symbol | Bool)
    q.open("Delete file?") { |yes| answer = yes }

    q.destroy

    # A later 'q' (the default quit key) must not be swallowed by the stale
    # accelerator, and must not run the confirmation callback on the dead dialog.
    e = Crysterm::Event::KeyPress.new 'q'
    w.emit e # must not raise out of the input path
    answer.should eq(:unset)
    e.accepted?.should be_false

    # And Enter is likewise not captured.
    e2 = Crysterm::Event::KeyPress.new '\r', ::Tput::Key::Enter
    w.emit e2
    e2.accepted?.should be_false
  end

  it "does not permanently swallow keys on the window after destroy" do
    w = headless_screen(40, 10, default_quit_keys: true)
    q = Widget::MessageBox.new parent: w, top: 0, left: 0, width: 40, height: 8
    q.open("Sure?") { }
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
    w = headless_screen(40, 10, default_quit_keys: true)
    stale = Widget::MessageBox.new parent: w, top: 0, left: 0, width: 40, height: 8
    stale.open("First?") { }
    stale.destroy

    q = Widget::MessageBox.new parent: w, top: 0, left: 0, width: 40, height: 8
    answer = :unset.as(Symbol | Bool)
    q.open("Second?") { |yes| answer = yes }

    e = Crysterm::Event::KeyPress.new 'y'
    w.emit e
    answer.should be_true
    e.accepted?.should be_true
  end

  it "destroy after a normal answer is a no-op (idempotent, does not raise)" do
    w = headless_screen(40, 10, default_quit_keys: true)
    q = Widget::MessageBox.new parent: w, top: 0, left: 0, width: 40, height: 8
    answer = :unset.as(Symbol | Bool)
    q.open("Sure?") { |yes| answer = yes }

    w.emit Crysterm::Event::KeyPress.new 'y'
    answer.should be_true

    q.destroy # must not raise, must not re-fire the callback
    answer.should be_true

    e = Crysterm::Event::KeyPress.new 'q'
    w.emit e
    e.accepted?.should be_false
  end
end

describe "BUGS17 B17-17: MessageBox#open (choices) tears down its accelerator on destroy" do
  it "destroy while an ask_choices is pending leaves no stale window handler" do
    w = headless_screen(40, 10, default_quit_keys: true)
    q = Widget::MessageBox.new parent: w, top: 0, left: 0, width: 40, height: 8
    picked = :unset.as(Symbol | Int32?)
    q.open("Pick", choices: ["A", "B", "C"]) { |idx| picked = idx }

    q.destroy

    # Escape must not be re-accepted (or re-raise) on a later press; the
    # choice navigation keys likewise must not stay captured.
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
