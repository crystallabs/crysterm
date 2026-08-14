require "./spec_helper"

include Crysterm

# `Widget::Chat::Autocomplete` + `Chat::Completion`: the trigger-key
# suggestion menu over the chat input — registry matching/ranking, open/close
# rules per trigger position, key navigation, accept (Enter/Tab) token
# replacement, and Escape-dismiss semantics.

private alias ChatInput = Crysterm::Widget::Chat::Input
private alias Autocomplete = Crysterm::Widget::Chat::Autocomplete
private alias Completion = Crysterm::Chat::Completion

private def item(name, desc = "", kind = Completion::Kind::Other)
  Completion::Item.new name, desc, kind
end

private def command_registry
  reg = Completion::Registry.new
  reg.register '/', [
    item("help", "Show help", Completion::Kind::Command),
    item("model", "Switch model", Completion::Kind::Command),
    item("memory", "Edit memory", Completion::Kind::Command),
  ]
  reg
end

# A focused chat input with an attached autocomplete, ready for synthesized
# keystrokes (emitted as events so both the controller's interceptor and the
# input's own reading listener run, in order).
private def build(s, reg = command_registry, top = 0)
  input = ChatInput.new parent: s, left: 0, top: top, width: 40
  ac = Autocomplete.new reg
  ac.attach input
  input.focus
  s.repaint
  {input, ac}
end

private def press(w, char : Char = '\0', key : ::Tput::Key? = nil)
  w.emit Crysterm::Event::KeyPress, kp(char, key)
end

private def type_str(w, str : String)
  str.each_char { |c| press w, c }
end

private def press_enter(w)
  press w, '\r', ::Tput::Key::Enter
end

describe Crysterm::Chat::Completion do
  it "ranks prefix matches before substring matches, case-insensitively" do
    reg = command_registry
    reg.complete('/', "mo").map(&.name).should eq ["model", "memory"]
    reg.complete('/', "MO").map(&.name).should eq ["model", "memory"]
    reg.complete('/', "xyz").should be_empty
  end

  it "yields all candidates for the empty query" do
    command_registry.complete('/', "").map(&.name).should eq ["help", "model", "memory"]
  end

  it "merges provider candidates and filters them like static ones" do
    reg = Completion::Registry.new
    reg.register('@') { |_q| [item("src/main.cr"), item("src/mixin.cr")] }
    reg.complete('@', "main").map(&.name).should eq ["src/main.cr"]
    reg.complete('@', "src").map(&.name).should eq ["src/main.cr", "src/mixin.cr"]
  end

  it "appends on repeat registration and reports an unknown trigger as empty" do
    reg = command_registry
    reg.register '/', [item("compact")]
    reg.complete('/', "").map(&.name).should eq ["help", "model", "memory", "compact"]
    reg.complete('?', "help").should be_empty
    reg.source?('/').try(&.anywhere?).should be_false
    reg.register('@') { |_q| [] of Completion::Item }
    reg.source?('@').try(&.anywhere?).should be_true
  end

  it "returns the static items array itself when the provider contributes nothing" do
    reg = command_registry
    src = reg.source?('/').not_nil!
    src.candidates("he").should be src.items # no provider — no copy

    reg.register('@') { |_q| [] of Completion::Item }
    empty_prov = reg.source?('@').not_nil!
    empty_prov.candidates("q").should be empty_prov.items # provider yields nothing — no copy
  end

  it "keeps case-insensitive matching correct as items grow after the folded memo is built" do
    reg = command_registry
    reg.complete('/', "he").map(&.name).should eq ["help"] # builds the folded-name memo
    reg.register '/', [item("Health")]                     # append → memo invalidated
    reg.complete('/', "HE").map(&.name).should eq ["help", "Health"]

    # Growth through the exposed `#items` reference is caught by the memo's
    # size guard.
    reg.source?('/').not_nil!.items << item("HELLO")
    reg.complete('/', "hell").map(&.name).should eq ["HELLO"]
  end
end

describe Crysterm::Widget::Chat::Autocomplete do
  it "opens on the trigger, filters as the user types, closes on no match" do
    s = headless_screen(60, 20)
    input, ac = build s

    type_str input, "/"
    ac.open?.should be_true
    pop = ac.@popup.not_nil!
    pop.items.size.should eq 3

    type_str input, "mo"
    pop.items.size.should eq 2
    pop.items.first.should start_with "/model"

    type_str input, "zz"
    ac.open?.should be_false
  end

  it "shows trigger-prefixed names with dimmed descriptions" do
    s = headless_screen(60, 20)
    input, ac = build s

    type_str input, "/he"
    pop = ac.@popup.not_nil!
    pop.items.should eq ["/help  {gray-fg}Show help{/gray-fg}"]
  end

  it "does not trigger a start-only prefix mid-buffer, but does trigger @ there" do
    s = headless_screen(60, 20)
    reg = command_registry
    reg.register('@') { |_q| [item("src/main.cr")] }
    input, ac = build s, reg

    type_str input, "hi /he"
    ac.open?.should be_false

    type_str input, " @src"
    ac.open?.should be_true
  end

  it "Enter accepts the highlighted row: token becomes trigger+name+space, no submit" do
    s = headless_screen(60, 20)
    input, ac = build s
    submitted = [] of String
    input.on(Crysterm::Event::Submitted) { |e| submitted << e.value }

    type_str input, "/mod"
    press_enter input

    input.value.should eq "/model "
    input.cursor_pos.should eq "/model ".size
    ac.open?.should be_false
    submitted.should be_empty

    # With the menu closed, Enter submits as usual (the completed text,
    # trailing space and all — `Input#submit` records it verbatim).
    press_enter input
    submitted.should eq ["/model "]
  end

  it "Tab accepts; Down moves the highlight to the next row first" do
    s = headless_screen(60, 20)
    input, _ac = build s

    type_str input, "/mo"
    press input, key: ::Tput::Key::Down
    press input, '\t', ::Tput::Key::Tab

    input.value.should eq "/memory "
  end

  it "replaces the whole token even with the caret inside it" do
    s = headless_screen(60, 20)
    reg = command_registry
    reg.register('@') { |_q| [item("src/main.cr")] }
    input, _ac = build s, reg

    type_str input, "see @src"
    press input, key: ::Tput::Key::Left # caret between "sr" and "c"; menu stays open
    press_enter input

    input.value.should eq "see @src/main.cr "
    input.cursor_pos.should eq "see @src/main.cr ".size
  end

  it "Escape dismisses; caret motion stays closed; typing reopens" do
    s = headless_screen(60, 20)
    input, ac = build s

    type_str input, "/he"
    ac.open?.should be_true

    press input, '\e', ::Tput::Key::Escape
    ac.open?.should be_false
    input.value.should eq "/he" # buffer untouched

    press input, key: ::Tput::Key::Left
    ac.open?.should be_false

    press input, key: ::Tput::Key::Right
    type_str input, "l"
    ac.open?.should be_true
  end

  it "keeps history keys on the input while the menu is closed" do
    s = headless_screen(60, 20)
    input, ac = build s

    type_str input, "hello"
    press_enter input
    input.value.should eq ""

    press input, key: ::Tput::Key::Up
    input.value.should eq "hello"
    ac.open?.should be_false
  end

  it "anchors the menu below a top input and above a bottom-anchored one" do
    s = headless_screen(60, 20)
    input, ac = build s
    type_str input, "/"
    pop = ac.@popup.not_nil!
    s.repaint
    pop.atop.should eq input.atop + input.aheight
    pop.aleft.should eq input.aleft
    pop.awidth.should eq input.awidth

    s2 = headless_screen(60, 20)
    input2, ac2 = build s2, command_registry, 17
    type_str input2, "/"
    pop2 = ac2.@popup.not_nil!
    s2.repaint
    (pop2.atop + pop2.aheight).should eq input2.atop
  end

  it "closes when focus leaves the input" do
    s = headless_screen(60, 20)
    input, ac = build s
    other = Crysterm::Widget::Box.new parent: s, top: 10, left: 0, width: 10, height: 3, focus_on_click: true

    type_str input, "/"
    ac.open?.should be_true
    other.focus
    ac.open?.should be_false
  end

  it "detach tears the popup down and stops watching" do
    s = headless_screen(60, 20)
    input, ac = build s

    type_str input, "/"
    ac.open?.should be_true
    ac.detach
    ac.open?.should be_false
    type_str input, "he"
    ac.open?.should be_false
    input.value.should eq "/he"
  end

  it "Shift+Enter passes through: inserts a newline instead of accepting" do
    s = headless_screen(60, 20)
    input, ac = build s

    type_str input, "/mod"
    ac.open?.should be_true

    # Shift+Enter only exists under an enhanced keyboard protocol, so it
    # arrives with a rich `KeyEvent` carrying the modifier.
    ke = ::Tput::KeyEvent.new 13, 'u', ::Tput::Modifiers::Shift
    input.emit Crysterm::Event::KeyPress,
      Crysterm::Event::KeyPress.new('\r', ::Tput::Key::Enter, key_event: ke)

    input.value.should eq "/mod\n" # no accept — the token was not replaced
    ac.open?.should be_false       # the newline boundary ended the token
  end

  it "a wheel over the menu border scrolls the list" do
    s = headless_screen(60, 20)
    reg = Completion::Registry.new
    reg.register '/', (1..12).map { |i| item("cmd#{i.to_s.rjust(2, '0')}") }
    input, ac = build s, reg

    type_str input, "/"
    pop = ac.@popup.not_nil!
    s.repaint
    pop.@item_boxes.size.should be > pop.visible_content_rows # must actually overflow

    # A wheel on the menu's border row (not over an item) goes through the
    # popup-level handler.
    s.dispatch_mouse mouse_ev(::Tput::Mouse::Action::WheelDown,
      pop.aleft + 2, pop.atop, ::Tput::Mouse::Button::None)
    s.repaint
    pop.@child_base.should be > 0
    ac.open?.should be_true
  end

  it "accept_handler observes the chosen item" do
    s = headless_screen(60, 20)
    input, ac = build s
    got = [] of Completion::Item
    ac.accept_handler { |it| got << it }

    type_str input, "/mod"
    press_enter input

    got.map(&.name).should eq ["model"]
    got.first.kind.command?.should be_true
  end
end
