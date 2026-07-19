require "./spec_helper"

include Crysterm

# Unit spec for `Overlay::DismissSession` (FORMAL-WIDGETS Part A / Piece 2): the
# plain "modal grab + click-away-to-dismiss" value object shared by
# `Mixin::Popup`, `Completer` and `Menu`. Serves both the grab-owner shape and
# the non-grab (Completer) shape, with an idempotent `#close`.

private def ds_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false)
end

private def down_at(s, x, y)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test)
end

describe Crysterm::Overlay::DismissSession do
  it "grabs on open and dismisses on a press outside the inside-region" do
    s = ds_screen
    w = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 3
    s._render

    dismissed = 0
    sess = Crysterm::Overlay::DismissSession.new(
      s, grab_owner: w,
      inside: ->(x : Int32, y : Int32) { w.contains_point?(x, y) }) { dismissed += 1 }

    sess.open?.should be_false
    sess.open
    sess.open?.should be_true
    s.popup_grab_active?.should be_true # modal grab taken

    down_at s, 1, 1 # inside w → not a dismiss
    dismissed.should eq 0

    down_at s, 60, 20 # outside → dismiss fires
    dismissed.should eq 1
  end

  it "releases the grab and detaches on close, idempotently" do
    s = ds_screen
    w = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 3
    s._render

    sess = Crysterm::Overlay::DismissSession.new(
      s, grab_owner: w,
      inside: ->(x : Int32, y : Int32) { w.contains_point?(x, y) }) { }
    sess.open
    s.popup_grab_active?.should be_true

    sess.close
    sess.open?.should be_false
    s.popup_grab_active?.should be_false
    sess.close # idempotent — no crash, no double-ungrab
    s.popup_grab_active?.should be_false
  end

  it "takes no grab when grab_owner is nil (the Completer shape)" do
    s = ds_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 3
    s._render

    dismissed = 0
    sess = Crysterm::Overlay::DismissSession.new(
      s, grab_owner: nil,
      inside: ->(x : Int32, y : Int32) { box.contains_point?(x, y) }) { dismissed += 1 }
    sess.open
    s.popup_grab_active?.should be_false # no modal grab

    down_at s, 60, 20 # still dismisses on an outside press
    dismissed.should eq 1
  end
end
