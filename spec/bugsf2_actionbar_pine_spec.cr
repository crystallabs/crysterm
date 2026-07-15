require "./spec_helper"

include Crysterm

# Regression specs for BUGS-F2 findings owned by the action-bar / interactive /
# Pine files:
#   8  — ActionBar per-command hotkeys: `accepted?` guard + detach/attach lifecycle
#   9  — Pine::MessageView/TextView registered their key handler twice
#   15 — ActionBar#select_index before first render never moved `selected`
#   30 — Mixin::Interactive scroll handler never `accept`ed handled keys
#   43 — Pine::OptionList inline editing neither accepted nor stopped its keys

private def f2_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Build a KeyPress event (so the caller can inspect `accepted?` afterwards).
private def kp(char : Char = '\0', key : Tput::Key? = nil)
  Crysterm::Event::KeyPress.new(char, key)
end

# Dispatch a KeyPress to a widget's own `on_keypress`, returning the event.
private def press(w, char : Char = '\0', key : Tput::Key? = nil)
  e = kp(char, key)
  w.on_keypress e
  e
end

# Emit a KeyPress through the object's registered handlers (so double
# registrations fire twice), returning the event for `accepted?` inspection.
private def emit_kp(w, char : Char = '\0', key : Tput::Key? = nil)
  e = kp(char, key)
  w.emit Crysterm::Event::KeyPress, e
  e
end

describe "BUGS-F2 #8 ActionBar per-command hotkeys" do
  it "does not fire a hotkey a focused widget already consumed" do
    s = f2_screen
    fired = 0
    bar = Crysterm::Widget::ListBar.new parent: s
    bar.add_item("quit", -> { fired += 1; nil }, keys: ["q"])
    s._render

    # A pre-accepted 'q' (e.g. typed into a LineEdit that consumed it) must not
    # trigger the command.
    e = kp('q')
    e.accept
    s.emit Crysterm::Event::KeyPress, e
    fired.should eq 0
  end

  it "fires the hotkey for an unconsumed matching character" do
    s = f2_screen
    fired = 0
    bar = Crysterm::Widget::ListBar.new parent: s
    bar.add_item("quit", -> { fired += 1; nil }, keys: ["q"])
    s._render

    emit_kp(s, 'q')
    fired.should eq 1
  end

  it "uninstalls the hotkey on detach and reinstalls it on re-attach" do
    s = f2_screen
    fired = 0
    bar = Crysterm::Widget::ListBar.new parent: s
    bar.add_item("quit", -> { fired += 1; nil }, keys: ["q"])
    s._render

    emit_kp(s, 'q')
    fired.should eq 1

    # Detach: the window-level hotkey must stop firing (no leak past removal).
    s.remove bar
    emit_kp(s, 'q')
    fired.should eq 1

    # Re-attach: the hotkey is reinstalled and fires again (and not doubled).
    s << bar
    emit_kp(s, 'q')
    fired.should eq 2
  end
end

describe "BUGS-F2 #15 ActionBar#select_index before first render moves `selected`" do
  it "sets `selected` to the target index so Enter fires the right command" do
    s = f2_screen
    fired = [] of Int32
    bar = Crysterm::Widget::ListBar.new parent: s
    bar.add_item("zero", -> { fired << 0; nil })
    bar.add_item("one", -> { fired << 1; nil })
    bar.add_item("two", -> { fired << 2; nil })

    # No render yet: `@lpos` is nil.
    bar.select_index 2
    bar.selected.should eq 2

    # Enter activates `selected`; it must run command 2, not the stale 0.
    press bar, key: Tput::Key::Enter
    fired.should eq [2]
  end
end

describe "BUGS-F2 #9 Pine::TextView / MessageView single key handler" do
  it "TextView fires its scroll handler once per key (not twice) and accepts it" do
    s = f2_screen
    body = (1..40).map { |i| "line #{i}" }.join('\n')
    view = Crysterm::Widget::Pine::TextView.new body,
      parent: s, top: 0, left: 0, width: 40, height: 10
    s._render

    # One direct invocation of the override = the intended per-key delta.
    view.on_keypress kp(key: Tput::Key::Down)
    single = view.get_scroll
    single.should be > 0

    # Emitting through the registered handler(s) must move the SAME amount — the
    # old duplicate registration ran `on_keypress` twice, moving twice as far.
    view.reset_scroll
    view.get_scroll.should eq 0
    e = emit_kp(view, key: Tput::Key::Down)
    view.get_scroll.should eq single
    e.accepted?.should be_true
  end

  it "MessageView fires its scroll handler once per key (not twice) and accepts it" do
    s = f2_screen
    body = (1..40).map { |i| "line #{i}" }.join('\n')
    view = Crysterm::Widget::Pine::MessageView.new(
      parent: s, top: 0, left: 0, width: 40, height: 10, body: body)
    s._render

    view.on_keypress kp(key: Tput::Key::Down)
    single = view.get_scroll
    single.should be > 0

    view.reset_scroll
    view.get_scroll.should eq 0
    e = emit_kp(view, key: Tput::Key::Down)
    view.get_scroll.should eq single
    e.accepted?.should be_true
  end
end

describe "BUGS-F2 #30 Mixin::Interactive accepts handled keys" do
  it "accepts a navigation key it consumed" do
    s = f2_screen
    input = Crysterm::Widget::Input.new(
      parent: s, width: "100%", height: "100%",
      scrollable: true, keys: true, vi: true,
      content: (1..60).map { |i| "line #{i}" }.join('\n'))
    s._render

    e = emit_kp(input, key: Tput::Key::Down)
    input.get_scroll.should be > 0
    e.accepted?.should be_true
  end

  it "leaves an unrelated key unaccepted (propagates to ancestors)" do
    s = f2_screen
    input = Crysterm::Widget::Input.new(
      parent: s, width: "100%", height: "100%",
      scrollable: true, keys: true, vi: true,
      content: (1..60).map { |i| "line #{i}" }.join('\n'))
    s._render

    e = emit_kp(input, 'x')
    e.accepted?.should be_false
  end
end

private def pine_options
  [
    Crysterm::Widget::Pine::OptionList::Option.new("line-wrap",
      Crysterm::Widget::Pine::OptionKind::Toggle,
      "Wrap long lines", value: "true"),
    Crysterm::Widget::Pine::OptionList::Option.new("signature",
      Crysterm::Widget::Pine::OptionKind::Text,
      "Signature", value: "hi"),
  ]
end

describe "BUGS-F2 #43 Pine inline editing / Space-toggle accept their keys" do
  it "OptionList accepts typed characters and Enter/Escape while editing" do
    s = f2_screen
    ol = Crysterm::Widget::Pine::OptionList.new pine_options, parent: s
    ol.select_index 1
    ol.activate # begin editing the Text option
    ol.editing?.should be_true

    press(ol, 'X').accepted?.should be_true
    press(ol, key: Tput::Key::Enter).accepted?.should be_true # commit
    ol.editing?.should be_false
  end

  it "OptionList accepts Escape while editing" do
    s = f2_screen
    ol = Crysterm::Widget::Pine::OptionList.new pine_options, parent: s
    ol.select_index 1
    ol.activate
    press(ol, key: Tput::Key::Escape).accepted?.should be_true
    ol.editing?.should be_false
  end

  it "OptionList accepts Space toggling a Toggle option" do
    s = f2_screen
    ol = Crysterm::Widget::Pine::OptionList.new pine_options, parent: s
    ol.select_index 0
    press(ol, ' ').accepted?.should be_true
  end

  it "Setup accepts Space toggling the selected feature" do
    s = f2_screen
    setup = Crysterm::Widget::Pine::Setup.new(
      [Crysterm::Widget::Pine::Setup::Option.new("enable-x", "desc")],
      parent: s)
    setup.select_index 0
    press(setup, ' ').accepted?.should be_true
  end

  it "ListSelect (multi) accepts Space toggling the current row" do
    s = f2_screen
    picker = Crysterm::Widget::Pine::ListSelect(String).new(
      ["Apricot", "Banana"],
      label: ->(x : String) { x },
      multi: true,
      parent: s)
    picker.select_index 0
    press(picker, ' ').accepted?.should be_true
  end
end
