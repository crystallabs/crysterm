require "./spec_helper"

# WP-12 — app loop, input, shortcuts (D3/D5/D12):
#   * Channel-driven `Application#exec`/`#quit` + `Window#quit` (D3)
#   * `on_key` shortcut sugar (Window + Widget) and `Crysterm::Key` alias
#   * `Widget#grab_mouse`/`release_mouse`/`grab_keyboard`/`release_keyboard`
#   * `FocusPolicy` (D5) + key-enabled-by-default interactive constructors
#   * `Widget#add_action` (QWidget parity) with working accelerators
#   * `Event::Mouse#local_x`/`#local_y` (widget-content-relative coordinates)
#   * `Window#layout=` auto-managed full-screen root box (D12)

private def wp12_window
  Crysterm::Window.new(width: 40, height: 12, default_quit_keys: false)
end

# Spawns `app.exec(window)` on its own fiber and waits until the loop is
# entered (the window is registered), returning the status channel.
private def wp12_exec(app, s)
  done = Channel(Int32).new
  spawn { done.send app.exec(s) }
  until app.windows.includes?(s)
    Fiber.yield
  end
  done
end

describe "WP-12 app loop, input, shortcuts" do
  describe "Application#exec / #quit (D3)" do
    it "exec blocks until quit and returns its status" do
      s = wp12_window
      app = Crysterm::Application.new
      done = wp12_exec app, s
      app.quit 7
      done.receive.should eq 7
      s.destroyed?.should be_true
    end

    it "destroying the last window ends exec with status 0" do
      s = wp12_window
      app = Crysterm::Application.new
      done = wp12_exec app, s
      s.destroy
      done.receive.should eq 0
    end

    it "Window#quit is the canonical spelling and carries the status" do
      s = wp12_window
      app = Crysterm::Application.new
      done = wp12_exec app, s
      s.quit 3
      done.receive.should eq 3
    end

    it "emits AboutToQuit before teardown" do
      s = wp12_window
      app = Crysterm::Application.new
      done = wp12_exec app, s
      about = false
      app.on(Crysterm::Event::AboutToQuit) { about = true }
      app.quit
      done.receive
      about.should be_true
    end
  end

  describe "on_key shortcut sugar" do
    it "fires on char and symbol keys, accepting the press" do
      s = wp12_window
      fired = 0
      s.on_key('x', :escape) { fired += 1 }

      e = Crysterm::Event::KeyPress.new 'x'
      s.emit e
      fired.should eq 1
      e.accepted?.should be_true

      s.emit Crysterm::Event::KeyPress.new '\0', Tput::Key::Escape
      fired.should eq 2

      # Unrelated key: untouched, unaccepted.
      other = Crysterm::Event::KeyPress.new 'y'
      s.emit other
      fired.should eq 2
      other.accepted?.should be_false
    end

    it "does not fire on an already-accepted press" do
      s = wp12_window
      fired = 0
      s.on_key('x') { fired += 1 }
      e = Crysterm::Event::KeyPress.new 'x'
      e.accept
      s.emit e
      fired.should eq 0
    end

    it "works on a focused widget" do
      s = wp12_window
      b = Crysterm::Widget::Box.new parent: s, keys: true, width: 5, height: 3
      fired = 0
      b.on_key('z') { fired += 1 }
      b.focus
      s.emit Crysterm::Event::KeyPress.new 'z'
      fired.should eq 1
    end

    it "Crysterm::Key aliases Tput::Key" do
      Crysterm::Key::Enter.should eq Tput::Key::Enter
    end
  end

  describe "Widget grab façades" do
    it "grab_mouse captures via the window; release is self-guarded" do
      s = wp12_window
      a = Crysterm::Widget::Box.new parent: s, width: 5, height: 3
      b = Crysterm::Widget::Box.new parent: s, left: 10, width: 5, height: 3
      a.grab_mouse
      s.mouse_captor.should be a
      b.release_mouse # not the captor: must not break a's gesture
      s.mouse_captor.should be a
      a.release_mouse
      s.mouse_captor.should be_nil
    end

    it "grab_keyboard focuses and sets the window grab; release is focus-guarded" do
      s = wp12_window
      a = Crysterm::Widget::Box.new parent: s, keys: true, width: 5, height: 3
      b = Crysterm::Widget::Box.new parent: s, left: 10, keys: true, width: 5, height: 3
      a.grab_keyboard
      a.focused?.should be_true
      s.grab_keys?.should be_true
      b.release_keyboard # unfocused: nothing to release
      s.grab_keys?.should be_true
      a.release_keyboard
      s.grab_keys?.should be_false
    end
  end

  describe "FocusPolicy (D5)" do
    it "derives from the legacy flags until set explicitly" do
      s = wp12_window
      plain = Crysterm::Widget::Box.new parent: s, width: 5, height: 3
      plain.focus_policy.none?.should be_true

      keyed = Crysterm::Widget::Box.new parent: s, keys: true, width: 5, height: 3
      keyed.focus_policy.strong?.should be_true

      tab_only = Crysterm::Widget::Box.new parent: s, keys: true, focus_on_click: false, width: 5, height: 3
      tab_only.focus_policy.tab?.should be_true
    end

    it "explicit assignment syncs the legacy flags" do
      s = wp12_window
      b = Crysterm::Widget::Box.new parent: s, keys: true, width: 5, height: 3

      b.focus_policy = :none
      b.keys?.should be_false
      b.keyable?.should be_false

      b.focus_policy = :click
      b.keys?.should be_true
      b.focus_on_click?.should be_true
      b.accepts_tab_focus?.should be_false

      b.focus_policy = :strong
      b.accepts_tab_focus?.should be_true
      # Qt rule under an explicit policy: only Wheel grants wheel-focus.
      b.accepts_wheel_focus?.should be_false
      b.focus_policy = :wheel
      b.accepts_wheel_focus?.should be_true
    end

    it "Tab navigation skips Click-policy widgets" do
      s = wp12_window
      w1 = Crysterm::Widget::Box.new parent: s, keys: true, width: 5, height: 3
      w2 = Crysterm::Widget::Box.new parent: s, left: 6, keys: true, width: 5, height: 3
      w3 = Crysterm::Widget::Box.new parent: s, left: 12, keys: true, width: 5, height: 3
      w2.focus_policy = :click

      w1.focus
      s.focus_next
      s.focused.should be w3
      s.focus_next
      s.focused.should be w1
      s.focus_previous
      s.focused.should be w3
    end

    it "interactive constructors are key-enabled by default, caller wins" do
      s = wp12_window
      Crysterm::Widget::Button.new(parent: s).keys?.should be_true
      Crysterm::Widget::Checkbox.new(parent: s).keys?.should be_true
      Crysterm::Widget::Slider.new(parent: s).keys?.should be_true
      Crysterm::Widget::SpinBox.new(parent: s).keys?.should be_true
      Crysterm::Widget::ComboBox.new(parent: s).keys?.should be_true
      # An explicit caller argument still wins.
      Crysterm::Widget::Button.new(parent: s, keys: false).keys?.should be_false
    end
  end

  describe "Widget#add_action" do
    it "installs a window-wide accelerator; remove_action withdraws it" do
      s = wp12_window
      b = Crysterm::Widget::Box.new parent: s, keys: true, width: 5, height: 3
      act = Crysterm::Action.new "bold", shortcut: Tput::Key::CtrlB
      triggered = 0
      act.on(Crysterm::Event::Triggered) { triggered += 1 }

      b.add_action act
      b.actions.should eq [act]
      s.emit Crysterm::Event::KeyPress.new '\0', Tput::Key::CtrlB
      triggered.should eq 1

      b.remove_action act
      s.emit Crysterm::Event::KeyPress.new '\0', Tput::Key::CtrlB
      triggered.should eq 1
    end

    it "gates Widget-context shortcuts on the host holding focus" do
      s = wp12_window
      host = Crysterm::Widget::Box.new parent: s, keys: true, width: 5, height: 3
      other = Crysterm::Widget::Box.new parent: s, left: 10, keys: true, width: 5, height: 3
      act = Crysterm::Action.new "ctx", shortcut: Tput::Key::CtrlG,
        shortcut_context: :widget
      triggered = 0
      act.on(Crysterm::Event::Triggered) { triggered += 1 }
      host.add_action act

      other.focus
      s.emit Crysterm::Event::KeyPress.new '\0', Tput::Key::CtrlG
      triggered.should eq 0

      host.focus
      s.emit Crysterm::Event::KeyPress.new '\0', Tput::Key::CtrlG
      triggered.should eq 1
    end
  end

  describe "Event::Mouse local coordinates" do
    it "delivers content-relative local_x/local_y to the widget target" do
      s = wp12_window
      b = Crysterm::Widget::Box.new parent: s, left: 5, top: 2, width: 10, height: 5,
        style: Crysterm::Style.new(border: true)
      got = nil
      b.on(Crysterm::Event::Mouse) { |e| got = {e.local_x, e.local_y, e.target} }
      s.repaint
      s.dispatch_mouse ::Tput::Mouse::Event.new(
        ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, 8, 4, source: :test)
      # Content origin is (5+1, 2+1) with the border inset.
      got.should eq({2, 1, b})
    end

    it "window-level emit has no target and falls back to absolute" do
      s = wp12_window
      got = nil
      s.on(Crysterm::Event::Mouse) { |e| got = {e.local_x, e.local_y, e.target} }
      s.dispatch_mouse ::Tput::Mouse::Event.new(
        ::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, 7, 3, source: :test)
      got.should eq({7, 3, nil})
    end
  end

  describe "Window#layout= (D12)" do
    it "lazily creates one full-screen root box and swaps engines on it" do
      s = wp12_window
      s.layout_root.should be_nil

      eng = Crysterm::Layout::Box.new :vertical
      s.layout = eng
      root = s.layout_root.not_nil!
      s.children.includes?(root).should be_true
      root.width.should eq "100%"
      root.height.should eq "100%"
      s.layout.should be eng

      eng2 = Crysterm::Layout::Box.new :horizontal
      s.layout = eng2
      s.layout_root.should be root
      s.layout.should be eng2
    end
  end
end
