require "./spec_helper"

include Crysterm

# API polish landed across the event catalog, `Action`, the reactive layer,
# `Widget#destroy` and the config front door.

private def a5_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "Event::Triggered payload" do
  it "carries the action that fired" do
    a = Action.new "Save"
    seen = [] of Action
    a.on_triggered { |e| seen << e.action }
    a.trigger
    seen.size.should eq 1
    seen.first.same?(a).should be_true
  end

  it "preserves the member action when an ActionGroup relays it" do
    g = ActionGroup.new
    one = g.add_action "One"
    two = g.add_action "Two"
    relayed = [] of {String, Bool}
    g.on_triggered { |e| relayed << {e.action.text, e.checked} }

    two.trigger
    one.trigger

    relayed.should eq [{"Two", true}, {"One", true}]
  end
end

describe "Action#checked= on a non-checkable action" do
  it "is a no-op and emits nothing (matching #toggle)" do
    a = Action.new "Run"
    toggles = 0
    changes = 0
    a.on_toggled { toggles += 1 }
    a.on_changed { changes += 1 }

    a.checked = true
    a.checked?.should be_false
    a.toggle
    a.checked?.should be_false

    toggles.should eq 0
    changes.should eq 0
  end

  it "still works once the action is checkable" do
    a = Action.new "Bold"
    a.checkable = true
    a.checked = true
    a.checked?.should be_true
  end
end

describe "Action.new(parent:)" do
  it "installs the action on the parent widget" do
    win = a5_window
    box = Crysterm::Widget::Box.new parent: win, width: 10, height: 3
    a = Action.new "Save", box, shortcut: ::Tput::Key::CtrlS

    a.parent.try(&.same?(box)).should be_true
    box.actions.includes?(a).should be_true
    a.associated_widgets.includes?(box).should be_true
  ensure
    win.try &.destroy
  end

  it "fires the installed shortcut on the parent's window" do
    win = a5_window
    box = Crysterm::Widget::Box.new parent: win, width: 10, height: 3
    fired = 0
    a = Action.new "Save", box, shortcut: ::Tput::Key::CtrlS
    a.on_triggered { fired += 1 }

    win.emit Crysterm::Event::KeyPress, kp(key: ::Tput::Key::CtrlS)
    fired.should eq 1
  ensure
    win.try &.destroy
  end
end

describe "Action.parse_key_sequence" do
  it "parses Qt key-sequence syntax" do
    Action.parse_key_sequence("Ctrl+B").should eq [::Tput::Key::CtrlB]
    Action.parse_key_sequence("Ctrl+K, Ctrl+B").should eq [::Tput::Key::CtrlK, ::Tput::Key::CtrlB]
  end

  it "also accepts the display-label spellings the two vocabularies share" do
    Action.parse_key_sequence("^X").should eq [::Tput::Key::CtrlX]
    Action.parse_key_sequence("^K, ^B").should eq [::Tput::Key::CtrlK, ::Tput::Key::CtrlB]
    Action.parse_key_sequence("PgDn").should eq [::Tput::Key::PageDown]
    Action.parse_key_sequence("Dn").should eq [::Tput::Key::Down]
    Action.parse_key_sequence("Ret").should eq [::Tput::Key::Enter]
  end

  it "raises on an unrecognized stroke" do
    expect_raises(ArgumentError, /Nonsense/) { Action.parse_key_sequence("Nonsense") }
  end
end

describe "Event::Mouse#snapshot" do
  it "detaches from the pool so a retained event keeps its values" do
    ev = ::Tput::Mouse::Event.new(
      action: ::Tput::Mouse::Action::Down,
      button: ::Tput::Mouse::Button::Left,
      x: 3, y: 4)
    e = Crysterm::Event::Mouse.new ev
    kept = e.snapshot

    later = ::Tput::Mouse::Event.new(
      action: ::Tput::Mouse::Action::Up,
      button: ::Tput::Mouse::Button::Left,
      x: 9, y: 9)
    e.reset later

    e.x.should eq 9
    kept.x.should eq 3
    kept.y.should eq 4
    kept.action.down?.should be_true
  end

  it "keeps the concrete event class" do
    ev = ::Tput::Mouse::Event.new(
      action: ::Tput::Mouse::Action::Move,
      button: ::Tput::Mouse::Button::Left,
      x: 1, y: 1)
    Crysterm::Event::MouseEnter.new(ev).snapshot.class.should eq Crysterm::Event::MouseEnter
  end
end

describe "Event::DeviceResize" do
  it "resizes the screen and fans a parameterless Resize out to descendants" do
    win = a5_window
    box = Crysterm::Widget::Box.new parent: win, width: 10, height: 3
    resizes = 0
    box.on_resize { resizes += 1 }

    win.emit Crysterm::Event::DeviceResize, Crysterm::Size.new(70, 20)

    resizes.should be >= 1
  ensure
    win.try &.destroy
  end
end

describe "Widget#destroy handler ownership" do
  it "drops every handler registered on the widget, after Destroy has fired" do
    win = a5_window
    box = Crysterm::Widget::Box.new parent: win, width: 10, height: 3
    destroyed = 0
    box.on_destroy { destroyed += 1 }
    box.on_resize { }

    box.destroy

    destroyed.should eq 1
    box.handlers(Crysterm::Event::Destroy).size.should eq 0
    box.handlers(Crysterm::Event::Resize).size.should eq 0
  ensure
    win.try &.destroy
  end
end

describe "Reactive ownership" do
  it "binds against a non-widget owner (an Action)" do
    owner = Action.new "Owner"
    count = Crysterm::Reactive::Property.new 0
    seen = [] of Int32
    Crysterm::Reactive.bind(owner, count) { seen << count.value }

    count.value = 2
    seen.should eq [0, 2]
  end

  it "uses its own change event, distinct from Event::Changed" do
    p = Crysterm::Reactive::Property.new 0
    reactive = 0
    action_style = 0
    p.on_reactive_changed { reactive += 1 }
    p.on_changed { action_style += 1 }

    p.value = 1

    reactive.should eq 1
    action_style.should eq 0
  end
end

describe "Crysterm.configure!" do
  it "leaves the application's ARGV untouched and ignores the generic --config" do
    argv = ["--config", "/nonexistent-a5.yml", "--window-grab-keys", "positional"]
    before = argv.dup
    was = Crysterm::Config.window_grab_keys
    begin
      Crysterm.configure! file: "", env: false, argv: argv
      argv.should eq before
      Crysterm::Config.window_grab_keys.should be_true
    ensure
      Crysterm::Config.set "window.grab_keys", was
    end
  end

  it "registers the previously-escaped timeouts" do
    Crysterm::Config.screen_cell_query_timeout.should be_a Time::Span
    Crysterm::Config.terminal_handshake_timeout.should be_a Time::Span
  end
end

describe "Window#prompt" do
  it "refuses to park the render fiber" do
    win = a5_window
    err = nil.as(Exception?)
    win.on_rendered do
      win.prompt "To: "
    rescue ex
      err = ex
    end
    win.repaint

    err.try(&.message).to_s.should contain "spawn"
  ensure
    win.try &.destroy
  end
end
