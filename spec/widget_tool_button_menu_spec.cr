require "./spec_helper"

include Crysterm

private def tbm_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def wheel(dir : Tput::Mouse::Action, x = 0, y = 0)
  Crysterm::Event::Mouse.new(Tput::Mouse::Event.new(dir, Tput::Mouse::Button::Left, x, y))
end

private def sb_click(s, x, y)
  s.dispatch_mouse(Tput::Mouse::Event.new(Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, x, y, source: :test))
  s.dispatch_mouse(Tput::Mouse::Event.new(Tput::Mouse::Action::Up, Tput::Mouse::Button::Left, x, y, source: :test))
end

# Behavioral specs for `Widget::ToolButton`'s menu features (the default-action
# path is covered elsewhere): the `▾` indicator, `popup_mode` press semantics,
# and the wheel-cycles-menu-actions behavior.
describe Crysterm::Widget::ToolButton do
  describe "#menu=" do
    it "appends the ▾ indicator to the label when a menu is attached" do
      s = tbm_screen
      m = Crysterm::Widget::Menu.new
      m.add "One"
      tb = Crysterm::Widget::ToolButton.new parent: s, content: "Tools"
      tb.content.should eq "Tools"
      tb.menu = m
      tb.content.should eq "Tools ▾"
    end

    it "is idempotent — re-assigning the same menu leaves the label unchanged" do
      s = tbm_screen
      m = Crysterm::Widget::Menu.new
      tb = Crysterm::Widget::ToolButton.new parent: s, content: "T", menu: m
      tb.content.should eq "T ▾"
      tb.menu = m
      tb.content.should eq "T ▾" # not "T ▾ ▾"
    end
  end

  describe "#press with InstantPopup" do
    it "opens the menu instead of emitting Press" do
      s = tbm_screen
      m = Crysterm::Widget::Menu.new
      m.add "Only"
      tb = Crysterm::Widget::ToolButton.new parent: s, menu: m,
        popup_mode: Crysterm::Widget::ToolButton::PopupMode::InstantPopup
      s._render
      pressed = false
      tb.on(Crysterm::Event::Pressed) { pressed = true }
      tb.click
      pressed.should be_false   # InstantPopup: whole button is the drop-down
      m.visible?.should be_true # the menu was popped up (shown)
    end
  end

  describe "MenuButtonPopup (default)" do
    it "presses on activation and opens the menu on the Down key" do
      s = tbm_screen
      m = Crysterm::Widget::Menu.new
      m.add "Item"
      tb = Crysterm::Widget::ToolButton.new parent: s, menu: m
      s._render

      pressed = false
      tb.on(Crysterm::Event::Pressed) { pressed = true }
      tb.click
      pressed.should be_true # default mode still presses

      ev = Crysterm::Event::KeyPress.new('\0', Tput::Key::Down)
      tb.on_keypress ev
      ev.accepted?.should be_true # Down was consumed to summon the menu
      m.visible?.should be_true   # ...and the menu is shown
    end
  end

  describe "#on_click" do
    it "opens the menu when the button is menu-only (no bound action)" do
      s = tbm_screen
      m = Crysterm::Widget::Menu.new
      m.add "Item"
      m.hide # stays hidden until summoned (as in real usage)
      tb = Crysterm::Widget::ToolButton.new parent: s, menu: m
      s._render

      pressed = false
      tb.on(Crysterm::Event::Pressed) { pressed = true }
      tb.on_click nil
      m.visible?.should be_true # a mouse click opens the drop-down...
      pressed.should be_false   # ...instead of emitting a bare Press
    end

    it "opens the menu on a click even when an action is bound" do
      s = tbm_screen
      m = Crysterm::Widget::Menu.new parent: s
      m.add "Item"
      m.hide
      act = Crysterm::Action.new "Apply"
      triggered = false
      act.on(Crysterm::Event::Triggered) { triggered = true }
      tb = Crysterm::Widget::ToolButton.new parent: s, default_action: act, menu: m
      s._render

      tb.on_click nil
      m.visible?.should be_true # a click opens the drop-down (the whole button)...
      triggered.should be_false # ...it doesn't run the action (that's Space/Enter)
    end
  end

  # A click anywhere on a menu-bearing tool button toggles its drop-down: the
  # whole surface is the affordance, so a click opens it and a second click (or a
  # click-away) closes it. A regression opened it only from the `▾` arrow and,
  # worse, a second click couldn't close it (the outside-dismiss shut the menu
  # and the same click reopened it).
  describe "click toggles the menu" do
    it "opens on the body and closes on a second body click" do
      s = tbm_screen
      m = Crysterm::Widget::Menu.new parent: s, width: 12, height: 3
      m.add "Rename"
      m.add "Delete"
      m.hide
      act = Crysterm::Action.new "Apply"
      tb = Crysterm::Widget::ToolButton.new parent: s, top: 3, left: 10,
        width: 12, height: 1, default_action: act, menu: m, align: :center
      s._render

      sb_click s, tb.aleft + 1, tb.atop # body, left of the ▾
      m.visible?.should be_true         # opened
      sb_click s, tb.aleft + 1, tb.atop # same spot again
      m.visible?.should be_false        # ...and closed (no reopen race)
    end

    it "opens on the ▾ arrow and closes on a second arrow click" do
      s = tbm_screen
      m = Crysterm::Widget::Menu.new parent: s, width: 12, height: 3
      m.add "Rename"
      m.hide
      act = Crysterm::Action.new "Apply"
      tb = Crysterm::Widget::ToolButton.new parent: s, top: 3, left: 10,
        width: 12, height: 1, default_action: act, menu: m, align: :center
      s._render

      sb_click s, tb.aleft + tb.awidth - 1, tb.atop # the arrow cell
      m.visible?.should be_true
      sb_click s, tb.aleft + tb.awidth - 1, tb.atop
      m.visible?.should be_false
    end
  end

  describe "wheel cycling" do
    it "triggers the menu's activatable actions in turn, skipping separators/disabled" do
      s = tbm_screen
      m = Crysterm::Widget::Menu.new
      fired = [] of String
      m.add("A") { fired << "A" }
      m.add_separator
      dis = m.add("D") { fired << "D" }
      dis.enabled = false
      m.add("B") { fired << "B" }

      tb = Crysterm::Widget::ToolButton.new parent: s, menu: m
      # First wheel-down lands on the first activatable action (index 0 + 1 wraps
      # within the 2-item activatable list => "B"), next wraps to "A".
      tb.emit Crysterm::Event::Mouse, wheel(Tput::Mouse::Action::WheelDown).mouse
      tb.emit Crysterm::Event::Mouse, wheel(Tput::Mouse::Action::WheelDown).mouse
      fired.should eq ["B", "A"] # separator + disabled never fire
      fired.includes?("D").should be_false
    end
  end
end
