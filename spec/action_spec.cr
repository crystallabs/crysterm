require "./spec_helper"

include Crysterm

# `Action` (src/action.cr, modeled on Qt's `QAction`) is not a widget, so it has
# no example under `examples/widget/`; these are the only tests of its
# activation/event behavior.
describe Crysterm::Action do
  describe "#activate" do
    it "emits Triggered by default" do
      a = Action.new
      fired = [] of String
      a.on(Event::Triggered) { fired << "triggered" }
      a.on(Event::Hovered) { fired << "hovered" }

      a.activate

      fired.should eq ["triggered"]
    end

    it "emits the event explicitly passed to it" do
      a = Action.new
      fired = [] of String
      a.on(Event::Triggered) { fired << "triggered" }
      a.on(Event::Hovered) { fired << "hovered" }

      a.activate :trigger
      a.activate :hover

      fired.should eq ["triggered", "hovered"]
    end

    it "runs every handler registered for the same event, in registration order" do
      a = Action.new
      order = [] of Int32
      a.on(Event::Triggered) { order << 1 }
      a.on(Event::Triggered) { order << 2 }

      a.activate :trigger

      order.should eq [1, 2]
    end

    it "does not fire Triggered handlers when only Hovered is activated" do
      a = Action.new
      triggered = 0
      a.on(Event::Triggered) { triggered += 1 }

      a.activate :hover

      triggered.should eq 0
    end

    it "does not fire Triggered when the action is disabled, but still hovers" do
      a = Action.new
      a.enabled = false
      fired = [] of String
      a.on(Event::Triggered) { fired << "triggered" }
      a.on(Event::Hovered) { fired << "hovered" }

      a.activate        # Triggered by default -> suppressed
      a.activate :hover # hover still notifies

      fired.should eq ["hovered"]

      # Re-enabling lets it trigger again.
      a.enabled = true
      a.activate
      fired.should eq ["hovered", "triggered"]
    end
  end

  # `Widgets` must alias the real `Crysterm::Action` (there is no
  # `Widget::Action`); guards against a broken `Action = Widget::Action` mapping.
  it "is reachable via the Widgets convenience namespace" do
    Crysterm::Widgets::Action.should eq Crysterm::Action
  end

  describe "checkable activation (Qt's activate(Trigger) toggle)" do
    it "toggles #checked itself and carries the new state on Triggered" do
      a = Action.new "Bold", checkable: true
      states = [] of Bool
      a.on(Event::Triggered) { |e| states << e.checked }

      a.activate
      a.checked?.should be_true
      a.activate
      a.checked?.should be_false

      states.should eq [true, false] # the post-toggle state each time
    end

    it "reports checked=false for a non-checkable action" do
      a = Action.new "Run"
      got = [] of Bool
      a.on(Event::Triggered) { |e| got << e.checked }
      a.activate
      got.should eq [false]
      a.checked?.should be_false
    end
  end

  describe "#toggle / #trigger / #hover slots" do
    it "#toggle flips a checkable action and emits Toggled but not Triggered" do
      a = Action.new "Wrap", checkable: true
      toggles = [] of Bool
      triggered = 0
      a.on(Event::Toggled) { |e| toggles << e.checked }
      a.on(Event::Triggered) { triggered += 1 }

      a.toggle
      a.toggle
      toggles.should eq [true, false]
      triggered.should eq 0
    end

    it "#toggle is a no-op for a non-checkable action" do
      a = Action.new "Run"
      fired = 0
      a.on(Event::Toggled) { fired += 1 }
      a.toggle
      a.checked?.should be_false
      fired.should eq 0
    end

    it "#trigger activates Triggered, #hover activates Hovered" do
      a = Action.new "X"
      seen = [] of String
      a.on(Event::Triggered) { seen << "t" }
      a.on(Event::Hovered) { seen << "h" }
      a.trigger
      a.hover
      seen.should eq ["t", "h"]
    end
  end

  describe "Toggled (Qt's toggled(bool))" do
    it "fires on any checked change, programmatic included, alongside Changed" do
      a = Action.new "Bold", checkable: true
      toggles = [] of Bool
      changed = 0
      a.on(Event::Toggled) { |e| toggles << e.checked }
      a.on(Event::Changed) { changed += 1 }

      a.checked = true
      a.checked = true # no-op, no emit
      a.checked = false

      toggles.should eq [true, false]
      changed.should eq 2
    end
  end

  describe "granular change events (Qt 6 enabledChanged/checkableChanged/visibleChanged)" do
    it "emits the specific event plus Changed, only on a real change" do
      a = Action.new "X"
      log = [] of String
      a.on(Event::EnabledChanged) { |e| log << "enabled=#{e.enabled}" }
      a.on(Event::CheckableChanged) { |e| log << "checkable=#{e.checkable}" }
      a.on(Event::VisibleChanged) { |e| log << "visible=#{e.visible}" }
      changed = 0
      a.on(Event::Changed) { changed += 1 }

      a.enabled = false
      a.enabled = false # no-op
      a.checkable = true
      a.visible = false

      log.should eq ["enabled=false", "checkable=true", "visible=false"]
      changed.should eq 3
    end
  end

  describe "#menu (Qt's QAction#menu, formerly #submenu)" do
    it "holds child actions and reports #menu?" do
      a = Action.new "File"
      a.menu?.should be_false
      a.menu = [Action.new("Open"), Action.new("Quit")]
      a.menu?.should be_true
      a.menu.try(&.size).should eq 2
    end

    it "treats an empty child list as no menu" do
      a = Action.new "File"
      a.menu = [] of Action
      a.menu?.should be_false
    end
  end

  describe "shortcuts (Qt's QKeySequence / shortcut / shortcuts)" do
    it "wraps a single key into a one-stroke sequence and renders text" do
      a = Action.new "Bold", shortcut: Tput::Key::CtrlB
      a.shortcut.should eq [Tput::Key::CtrlB]
      a.shortcut_text.should eq "CtrlB"
      a.shortcut_context.should eq Action::ShortcutContext::Window
    end

    it "supports multiple alternative sequences; #shortcut is the first" do
      a = Action.new "Find"
      a.shortcuts = [[Tput::Key::CtrlF], [Tput::Key::CtrlS]]
      a.shortcut.should eq [Tput::Key::CtrlF]
      a.shortcuts.size.should eq 2
    end

    it "matches a single-stroke shortcut against a KeyPress" do
      a = Action.new "Bold", shortcut: Tput::Key::CtrlB
      a.shortcut_matches?(Event::KeyPress.new('\0', Tput::Key::CtrlB)).should be_true
      a.shortcut_matches?(Event::KeyPress.new('\0', Tput::Key::CtrlA)).should be_false
    end

    it "does not match when the action is disabled" do
      a = Action.new "Bold", shortcut: Tput::Key::CtrlB, enabled: false
      a.shortcut_matches?(Event::KeyPress.new('\0', Tput::Key::CtrlB)).should be_false
    end
  end

  describe "keyword constructor" do
    it "applies all configured properties" do
      a = Action.new "Bold",
        icon_text: "B", checkable: true, checked: true, enabled: false,
        visible: false, auto_repeat: false, priority: Action::Priority::High,
        tool_tip: "Bold text", data: 7
      a.text.should eq "Bold"
      a.icon_text.should eq "B"
      a.checkable?.should be_true
      a.checked?.should be_true
      a.enabled?.should be_false
      a.visible?.should be_false
      a.auto_repeat?.should be_false
      a.priority.should eq Action::Priority::High
      a.tool_tip.should eq "Bold text"
      a.data.should eq 7
    end
  end
end

private def headless_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `ToolBar`/`MenuBar` install their actions' keyboard accelerators on the owning
# window, so a shortcut fires the action without clicking it.
describe "Action shortcut dispatch" do
  it "fires a ToolBar action when its shortcut is pressed on the window" do
    s = headless_window
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    bold = Action.new "Bold", checkable: true, shortcut: Tput::Key::CtrlB
    fired = [] of Bool
    bold.on(Event::Triggered) { |e| fired << e.checked }
    tb.add_action bold

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq [true] # toggled on + triggered
    bold.checked?.should be_true
  end

  it "stops firing after the action is uninstalled (bar detached)" do
    s = headless_window
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    a = Action.new "Run", shortcut: Tput::Key::CtrlR
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    tb.add_action a

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlR)
    fired.should eq 1

    a.uninstall_shortcut s
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlR)
    fired.should eq 1 # no further dispatch
  end

  it "fires a MenuBar menu action without opening the menu" do
    s = headless_window
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    copy = Action.new "Copy", shortcut: Tput::Key::CtrlC
    fired = 0
    copy.on(Event::Triggered) { fired += 1 }
    bar.add_menu "Edit", [copy]

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlC)
    fired.should eq 1
  end

  # Multi-keystroke chord: fires only once the whole sequence is entered, in order.
  it "fires a chord shortcut only after the full sequence" do
    s = headless_window
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    a = Action.new "Bold", shortcuts: [[Tput::Key::CtrlK, Tput::Key::CtrlB]]
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    tb.add_action a

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlK)
    fired.should eq 0 # prefix held, not yet fired
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1 # completed
  end

  it "resets a half-entered chord when a non-matching key interrupts it" do
    s = headless_window
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    a = Action.new "Bold", shortcuts: [[Tput::Key::CtrlK, Tput::Key::CtrlB]]
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    tb.add_action a

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlK) # start chord
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlA) # interrupt — resets
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB) # lone CtrlB, no match
    fired.should eq 0
    # The full sequence still works afterwards.
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlK)
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1
  end
end

describe "Action#icon (Unicode glyph)" do
  it "prepends the glyph in #display_label and leaves plain text when unset" do
    Action.new("Open", icon: "📁").display_label.should eq "📁 Open"
    Action.new("Open").display_label.should eq "Open"
  end

  it "is settable and emits Changed" do
    a = Action.new "Open"
    changed = 0
    a.on(Event::Changed) { changed += 1 }
    a.icon = "📁"
    a.icon.should eq "📁"
    changed.should eq 1
  end
end

# Reverse "added to" membership list, maintained by the host widgets' add/remove paths.
describe "Action#associated_widgets" do
  it "is empty until the action is added to a widget" do
    Action.new("X").associated_widgets.empty?.should be_true
  end

  it "records each host the action is added to, and the same action can have several" do
    s = headless_window
    menu = Crysterm::Widget::Menu.new parent: s
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    a = Action.new "Bold"

    menu << a
    tb.add_action a

    a.associated_widgets.should contain menu
    a.associated_widgets.should contain tb
    a.associated_widgets.size.should eq 2
  end

  it "does not double-register on repeated add" do
    s = headless_window
    menu = Crysterm::Widget::Menu.new parent: s
    a = Action.new "Bold"
    menu << a
    menu << a        # Menu#<< no-ops when already present
    a.associate menu # even a direct re-associate is idempotent
    a.associated_widgets.size.should eq 1
  end

  it "drops the host when the action is removed (Menu#remove_action)" do
    s = headless_window
    menu = Crysterm::Widget::Menu.new parent: s
    a = Action.new "Bold"
    menu << a
    a.associated_widgets.should contain menu
    menu.remove_action a
    a.associated_widgets.empty?.should be_true
  end

  it "removes via the #>> operator alias, like #remove_action" do
    s = headless_window
    menu = Crysterm::Widget::Menu.new parent: s
    a = Action.new "Bold"
    menu << a
    a.associated_widgets.should contain menu
    menu >> a
    a.associated_widgets.empty?.should be_true
    menu.count.should eq 0
  end
end
