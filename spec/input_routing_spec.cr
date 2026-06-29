require "./spec_helper"

include Crysterm

# Routing of `Tput::InputEvent`s to Crysterm events (`Window#dispatch_input`),
# exercised directly with constructed events — no TTY / input fiber needed.

private def routing_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def press(char : Char, key : Tput::Key? = nil)
  Tput::InputEvent.new char, key
end

private def release(number : Int32)
  ke = Tput::KeyEvent.new number, 'u', Tput::Modifiers::None, Tput::KeyEvent::Type::Release
  Tput::InputEvent.new '\0', nil, ['\0'], key_event: ke
end

describe "Window#dispatch_input" do
  it "routes a paste to Event::Paste with the verbatim content" do
    s = routing_screen
    got = [] of String
    s.on(Crysterm::Event::Paste) { |e| got << e.content }
    s.dispatch_input Tput::InputEvent.new('\0', paste: "a\e[Bb")
    got.should eq ["a\e[Bb"]
  end

  it "routes a key press to Event::KeyPress (not KeyRelease)" do
    s = routing_screen
    presses = [] of Tput::Key?
    releases = 0
    s.on(Crysterm::Event::KeyPress) { |e| presses << e.key }
    s.on(Crysterm::Event::KeyRelease) { |_| releases += 1 }
    s.dispatch_input press('a', Tput::Key::CtrlA)
    presses.should eq [Tput::Key::CtrlA]
    releases.should eq 0
  end

  it "routes a key release to Event::KeyRelease (not KeyPress)" do
    s = routing_screen
    presses = 0
    releases = 0
    s.on(Crysterm::Event::KeyPress) { |_| presses += 1 }
    s.on(Crysterm::Event::KeyRelease) { |_| releases += 1 }
    s.dispatch_input release('a'.ord)
    presses.should eq 0
    releases.should eq 1
  end

  it "delivers both press and release to the Event::Key catch-all" do
    s = routing_screen
    seen = [] of String
    s.on(Crysterm::Event::Key) { |e| seen << e.class.name.split("::").last }
    s.dispatch_input press('a', Tput::Key::CtrlA)
    s.dispatch_input release('a'.ord)
    seen.should eq ["KeyPress", "KeyRelease"]
  end

  it "routes a color-scheme report to Event::ColorScheme" do
    s = routing_screen
    got = [] of Tput::ColorScheme
    s.on(Crysterm::Event::ColorScheme) { |e| got << e.scheme }
    s.dispatch_input Tput::InputEvent.new('\0', color_scheme: Tput::ColorScheme::Dark)
    got.should eq [Tput::ColorScheme::Dark]
  end

  it "routes an (OSC-52) clipboard paste to Event::Paste" do
    s = routing_screen
    got = [] of String
    s.on(Crysterm::Event::Paste) { |e| got << e.content }
    s.dispatch_input Tput::InputEvent.new('\0', paste: "clipboard text")
    got.should eq ["clipboard text"]
  end

  it "consumes an in-band resize without emitting a key or paste" do
    s = routing_screen
    other = 0
    s.on(Crysterm::Event::KeyPress) { |_| other += 1 }
    s.on(Crysterm::Event::Paste) { |_| other += 1 }
    s.dispatch_input Tput::InputEvent.new('\0', resize: Tput::Resize.new(24, 80, 0, 0))
    other.should eq 0
  end
end
