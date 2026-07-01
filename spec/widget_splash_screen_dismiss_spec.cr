require "./spec_helper"

include Crysterm

private def splash_screen_win
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def splash_mouse_down
  Crysterm::Event::Mouse.new(
    Tput::Mouse::Event.new(Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, 0, 0))
end

# Complements the existing SplashScreen centering/finish spec: `#finish`
# idempotency, the `dismiss_on_event?` input-dismissal, and content replacement.
describe Crysterm::Widget::SplashScreen do
  it "emits Complete only once even if finished twice" do
    s = splash_screen_win
    sp = Crysterm::Widget::SplashScreen.new parent: s, width: 30, height: 8
    count = 0
    sp.on(Crysterm::Event::Complete) { count += 1 }
    sp.finish
    sp.finish # racing click + finish_after must not double-fire
    count.should eq 1
  end

  it "dismisses on a mouse press when dismiss_on_event? (default)" do
    s = splash_screen_win
    sp = Crysterm::Widget::SplashScreen.new parent: s, width: 30, height: 8
    sp.dismiss_on_event?.should be_true
    done = false
    sp.on(Crysterm::Event::Complete) { done = true }
    sp.emit Crysterm::Event::Mouse, splash_mouse_down.mouse
    done.should be_true
    s.children.includes?(sp).should be_false
  end

  it "does not dismiss on input when dismiss_on_event? is off" do
    s = splash_screen_win
    sp = Crysterm::Widget::SplashScreen.new parent: s, width: 30, height: 8, dismiss_on_event: false
    done = false
    sp.on(Crysterm::Event::Complete) { done = true }
    sp.emit Crysterm::Event::Mouse, splash_mouse_down.mouse
    done.should be_false
    s.children.includes?(sp).should be_true
  end

  it "replaces a previously set content widget" do
    s = splash_screen_win
    first = Crysterm::Widget::Box.new content: "old"
    sp = Crysterm::Widget::SplashScreen.new parent: s, width: 30, height: 8, content: first
    sp.content_widget.should be(first)

    second = Crysterm::Widget::Box.new content: "new"
    sp.content_widget = second
    sp.content_widget.should be(second)
    sp.children.includes?(first).should be_false # old one detached
    sp.children.includes?(second).should be_true
  end
end
