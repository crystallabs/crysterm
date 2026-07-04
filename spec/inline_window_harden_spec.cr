require "./spec_helper"

include Crysterm

private def inline_window(width : Int32? = nil, height : Int32? = 6)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height,
    alternate: false,
    default_quit_keys: false,
  )
end

describe "inline Window hardening" do
  it "pins height but lets width follow the terminal (per-axis explicit size)" do
    win = inline_window(width: nil, height: 5)
    win.screen.explicit_height?.should be_true
    win.screen.explicit_width?.should be_false
    win.aheight.should eq 5
    # Width was adopted from the terminal, not frozen at the Screen default (1).
    win.awidth.should eq win.tput.screen.width
    win.awidth.should be > 1
  end

  it "translates mouse rows back into surface space by the render offset" do
    win = inline_window(width: 40, height: 6)
    win.render_row_offset = 8

    seen_y = nil
    win.on(Crysterm::Event::Mouse) { |e| seen_y = e.y }

    # A press on physical row 8 (the region top) must surface as row 0.
    ev = ::Tput::Mouse::Event.new(
      action: ::Tput::Mouse::Action::Down,
      button: ::Tput::Mouse::Button::Left,
      x: 3, y: 8)
    win.dispatch_mouse ev

    seen_y.should eq 0
  end

  it "does not offset mouse rows in full-screen (offset 0) mode" do
    win = inline_window(width: 40, height: 6)
    win.render_row_offset.should eq 0

    seen_y = nil
    win.on(Crysterm::Event::Mouse) { |e| seen_y = e.y }
    ev = ::Tput::Mouse::Event.new(
      action: ::Tput::Mouse::Action::Down,
      button: ::Tput::Mouse::Button::Left,
      x: 3, y: 4)
    win.dispatch_mouse ev
    seen_y.should eq 4
  end

  it "clamps the inline offset on resize so the region never falls off the bottom" do
    win = inline_window(width: 40, height: 6)
    win.render_row_offset = 1000 # absurdly low anchor

    win.on_resize(Crysterm::Event::Resize.new)

    # Region top + height must stay within the terminal (or pinned to 0 when it
    # can't fit at all).
    (win.render_row_offset + win.aheight).should be <= {win.aheight, win.tput.screen.height}.max
    win.render_row_offset.should be >= 0
  end
end
