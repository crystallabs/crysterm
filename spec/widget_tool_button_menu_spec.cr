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
      tb.on(Crysterm::Event::Press) { pressed = true }
      tb.press
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
      tb.on(Crysterm::Event::Press) { pressed = true }
      tb.press
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
      tb.on(Crysterm::Event::Press) { pressed = true }
      tb.on_click nil
      m.visible?.should be_true # a mouse click opens the drop-down...
      pressed.should be_false   # ...instead of emitting a bare Press
    end

    it "activates the bound action (not the menu) when an action is present" do
      s = tbm_screen
      m = Crysterm::Widget::Menu.new
      m.add "Item"
      m.hide # stays hidden; the action's click must not summon it
      act = Crysterm::Action.new "Apply"
      triggered = false
      act.on(Crysterm::Event::Triggered) { triggered = true }
      tb = Crysterm::Widget::ToolButton.new parent: s, action: act, menu: m
      s._render

      tb.on_click nil
      triggered.should be_true   # click activates the action (reachable by mouse)
      m.visible?.should be_false # ...and the menu stays closed (Down opens it)
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
