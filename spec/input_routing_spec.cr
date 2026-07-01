require "./spec_helper"

include Crysterm

# Routing of `Tput::InputEvent`s to Crysterm events, exercised directly with
# constructed events — no TTY / input fiber needed. Two layers are covered:
#
#   * `Window#handle_input` — the per-surface demux (key/paste/mouse/resize).
#   * `Application#route_input` — device->surface dispatch: forwards a parsed
#     event to the active window on that device.

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

describe "Window#handle_input" do
  it "routes a paste to Event::Paste with the verbatim content" do
    s = routing_screen
    got = [] of String
    s.on(Crysterm::Event::Paste) { |e| got << e.content }
    s.handle_input Tput::InputEvent.new('\0', paste: "a\e[Bb")
    got.should eq ["a\e[Bb"]
  end

  it "routes a key press to Event::KeyPress (not KeyRelease)" do
    s = routing_screen
    presses = [] of Tput::Key?
    releases = 0
    s.on(Crysterm::Event::KeyPress) { |e| presses << e.key }
    s.on(Crysterm::Event::KeyRelease) { |_| releases += 1 }
    s.handle_input press('a', Tput::Key::CtrlA)
    presses.should eq [Tput::Key::CtrlA]
    releases.should eq 0
  end

  it "routes a key release to Event::KeyRelease (not KeyPress)" do
    s = routing_screen
    presses = 0
    releases = 0
    s.on(Crysterm::Event::KeyPress) { |_| presses += 1 }
    s.on(Crysterm::Event::KeyRelease) { |_| releases += 1 }
    s.handle_input release('a'.ord)
    presses.should eq 0
    releases.should eq 1
  end

  it "delivers both press and release to the Event::Key catch-all" do
    s = routing_screen
    seen = [] of String
    s.on(Crysterm::Event::Key) { |e| seen << e.class.name.split("::").last }
    s.handle_input press('a', Tput::Key::CtrlA)
    s.handle_input release('a'.ord)
    seen.should eq ["KeyPress", "KeyRelease"]
  end

  it "routes a color-scheme report to Event::ColorScheme" do
    s = routing_screen
    got = [] of Tput::ColorScheme
    s.on(Crysterm::Event::ColorScheme) { |e| got << e.scheme }
    s.handle_input Tput::InputEvent.new('\0', color_scheme: Tput::ColorScheme::Dark)
    got.should eq [Tput::ColorScheme::Dark]
  end

  it "routes an OSC-52 clipboard read reply to Event::Clipboard (not Paste)" do
    s = routing_screen
    clips = [] of String
    pastes = 0
    s.on(Crysterm::Event::Clipboard) { |e| clips << e.content }
    s.on(Crysterm::Event::Paste) { |_| pastes += 1 }
    s.handle_input Tput::InputEvent.new('\0', clipboard: "clip text")
    clips.should eq ["clip text"]
    pastes.should eq 0
  end

  it "consumes an in-band resize without emitting a key or paste" do
    s = routing_screen
    other = 0
    s.on(Crysterm::Event::KeyPress) { |_| other += 1 }
    s.on(Crysterm::Event::Paste) { |_| other += 1 }
    s.handle_input Tput::InputEvent.new('\0', resize: Tput::Resize.new(24, 80, 0, 0))
    other.should eq 0
  end
end

describe "Application#route_input" do
  it "forwards a parsed event to the active window on that device" do
    app = Crysterm::Application.new
    win = routing_screen
    app.add win

    got = [] of Tput::Key?
    win.on(Crysterm::Event::KeyPress) { |e| got << e.key }

    app.route_input win.screen, press('a', Tput::Key::CtrlA)
    got.should eq [Tput::Key::CtrlA]
  end

  it "routes to the window that owns the originating device, not the global active one" do
    app = Crysterm::Application.new
    win_a = routing_screen
    win_b = routing_screen
    app.add win_a
    app.add win_b # win_b is now the globally active window

    a_keys = [] of Tput::Key?
    b_keys = [] of Tput::Key?
    win_a.on(Crysterm::Event::KeyPress) { |e| a_keys << e.key }
    win_b.on(Crysterm::Event::KeyPress) { |e| b_keys << e.key }

    # Must reach win_a (its device), even though win_b is the active window.
    app.route_input win_a.screen, press('a', Tput::Key::CtrlA)
    a_keys.should eq [Tput::Key::CtrlA]
    b_keys.should be_empty
  end

  it "drops input from a device with no window (no error)" do
    app = Crysterm::Application.new
    orphan = routing_screen                                     # built but never added to the app
    app.route_input orphan.screen, press('a', Tput::Key::CtrlA) # no-op, not a raise
  end

  # The app-global quit path calls `exit`, so it can't be unit-tested directly.
  # Covers the opt-out side: `default_quit_keys: false` means `q` forwards as
  # an ordinary key instead of being intercepted.
  it "forwards 'q' to a default_quit_keys:false window instead of quitting" do
    app = Crysterm::Application.new
    win = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      default_quit_keys: false)
    app.add win
    got = [] of Char?
    win.on(Crysterm::Event::KeyPress) { |e| got << e.char }

    app.route_input win.screen, press('q')
    got.should eq ['q']
  end

  # `Application.quit_key?` is shared by the app-global hotkey and the graceful
  # wrapper quit (`.exec_all`); tested directly since the consuming loops are
  # IO-bound and can't run headlessly.
  it "recognizes the default quit keys via Application.quit_key?" do
    Crysterm::Application.quit_key?('q', nil).should be_true
    Crysterm::Application.quit_key?('\0', Tput::Key::CtrlQ).should be_true
    Crysterm::Application.quit_key?('a', nil).should be_false
    Crysterm::Application.quit_key?('\0', Tput::Key::CtrlA).should be_false
  end

  # `exec_all` opts its windows out of the app-global hard-exit for a graceful
  # close. Verifies the setter actually flips routing from hard-exit to
  # forward — the piece testable without the blocking loop.
  it "lets default_quit_keys= flip a window out of the hard-exit path" do
    app = Crysterm::Application.new
    win = routing_screen # defaults to default_quit_keys: true
    app.add win
    win.default_quit_keys?.should be_true

    # exec_all does exactly this to take over quit:
    win.default_quit_keys = false
    win.default_quit_keys?.should be_false

    got = [] of Char?
    win.on(Crysterm::Event::KeyPress) { |e| got << e.char }
    app.route_input win.screen, press('q')
    got.should eq ['q'] # forwarded, not hard-exited
  end

  it "refreshes the app clipboard cache from an OSC-52 read reply" do
    app = Crysterm::Application.new
    win = routing_screen
    app.add win

    got = [] of String
    win.on(Crysterm::Event::Clipboard) { |e| got << e.content }

    app.route_input win.screen, Tput::InputEvent.new('\0', clipboard: "from terminal")
    got.should eq ["from terminal"]
    app.clipboard.text.should eq "from terminal"
  end
end

describe "Application registry consistency" do
  it "drops a destroyed window from the registry and active_window" do
    app = Crysterm::Application.new
    a = routing_screen
    b = routing_screen
    app.add a
    app.add b
    app.windows.should eq [a, b]
    app.active_window.should be(b)

    b.destroy

    app.windows.includes?(b).should be_false
    app.active_window.should be(a)
  end

  it "stops routing input to a destroyed window" do
    app = Crysterm::Application.new
    win = routing_screen
    app.add win
    dev = win.screen
    got = 0
    win.on(Crysterm::Event::KeyPress) { |_| got += 1 }

    win.destroy
    app.route_input dev, press('a', Tput::Key::CtrlA) # device gone: no receiver, no raise
    got.should eq 0
  end
end
