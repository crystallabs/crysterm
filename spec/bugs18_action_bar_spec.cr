require "./spec_helper"

include Crysterm

# Regression specs for the BUGS18 ActionBar findings (shared by ListBar,
# MenuBar and ToolBar via `Mixin::ActionBar`):
#   B18-39/B18-100 — `#on_keypress` never accepted its handled keys, so vi 'q'
#                    also hit the app's default quit keys and Enter/Escape
#                    double-acted on window-level accelerators
#   B18-45  — negative indices slipped past `#remove_item`/`#select_item`/
#             `#activate_item`, removing/firing the *last* command while the
#             raw index corrupted the selection cursor
#   B18-102 — the per-command hotkey handler never accepted the keypress
#   B18-103 — `#items=` re-add kept stale auto-generated `N:` prefixes
#   B18-107 — `#activate_item` ran the callback without emitting `ItemActivated`

private def b18_screen
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

# Emit a KeyPress through the object's registered handlers (window-level
# accelerators included), returning the event for `accepted?` inspection.
private def emit_kp(w, char : Char = '\0', key : Tput::Key? = nil)
  e = kp(char, key)
  w.emit Crysterm::Event::KeyPress, e
  e
end

describe "BUGS18 B18-39/B18-100 ActionBar#on_keypress accepts handled keys" do
  it "accepts arrows, Tab/ShiftTab, vi h/l, Enter/vi k and Escape/vi q" do
    s = b18_screen
    bar = Crysterm::Widget::ListBar.new parent: s, keys: true, vi_keys: true
    bar.add_item("open", -> { nil })
    bar.add_item("save", -> { nil })
    s.repaint

    press(bar, key: Tput::Key::Left).accepted?.should be_true
    press(bar, key: Tput::Key::Right).accepted?.should be_true
    press(bar, key: Tput::Key::ShiftTab).accepted?.should be_true
    press(bar, key: Tput::Key::Tab).accepted?.should be_true
    press(bar, 'h').accepted?.should be_true
    press(bar, 'l').accepted?.should be_true
    press(bar, key: Tput::Key::Enter).accepted?.should be_true
    press(bar, 'k').accepted?.should be_true
    press(bar, key: Tput::Key::Escape).accepted?.should be_true
    press(bar, 'q').accepted?.should be_true
  end

  it "accepts the vi 'q' cancel even on an empty bar" do
    s = b18_screen
    bar = Crysterm::Widget::ListBar.new parent: s, keys: true, vi_keys: true
    s.repaint

    # An un-accepted 'q' would go on to `Application`'s default quit keys and
    # tear the whole app down.
    press(bar, 'q').accepted?.should be_true
    press(bar, key: Tput::Key::Escape).accepted?.should be_true
  end

  it "still fires the command and emits cancel events while accepting" do
    s = b18_screen
    fired = 0
    cancelled = [] of Int32
    bar = Crysterm::Widget::ListBar.new parent: s, keys: true, vi_keys: true
    bar.add_item("open", -> { fired += 1; nil })
    bar.on(Crysterm::Event::ItemCancelled) { |e| cancelled << e.index }
    s.repaint

    press(bar, key: Tput::Key::Enter)
    fired.should eq 1
    press(bar, 'q')
    cancelled.should eq [0]
  end

  it "lets genuinely unhandled keys bubble un-accepted" do
    s = b18_screen
    bar = Crysterm::Widget::ListBar.new parent: s, keys: true, vi_keys: true
    bar.add_item("open", -> { nil })
    s.repaint

    press(bar, 'x').accepted?.should be_false
    # vi chars must not be consumed when vi_keys is off.
    bar2 = Crysterm::Widget::ListBar.new parent: s, keys: true
    bar2.add_item("open", -> { nil })
    press(bar2, 'q').accepted?.should be_false
  end
end

describe "BUGS18 B18-45 ActionBar negative-index validation" do
  it "makes remove_item(-1) a no-op that leaves the cursor alone" do
    s = b18_screen
    bar = Crysterm::Widget::ListBar.new parent: s
    bar.add_item("a", -> { nil })
    bar.add_item("b", -> { nil })
    bar.add_item("c", -> { nil })
    s.repaint
    bar.select_item 1

    bar.remove_item(-1).should be_nil
    bar.count.should eq 3
    bar.current_index.should eq 1
  end

  it "makes select_item/activate_item with a negative index no-ops" do
    s = b18_screen
    fired = 0
    bar = Crysterm::Widget::ListBar.new parent: s
    bar.add_item("a", -> { nil })
    bar.add_item("b", -> { nil })
    bar.add_item("c", -> { fired += 1; nil })
    s.repaint
    bar.select_item 1

    bar.select_item(-1)
    bar.current_index.should eq 1

    bar.activate_item(-1)
    fired.should eq 0
    bar.current_index.should eq 1
  end
end

describe "BUGS18 B18-102 ActionBar per-command hotkey accepts the keypress" do
  it "accepts a matched hotkey so it can't double-act (or quit the app)" do
    s = b18_screen
    fired = 0
    bar = Crysterm::Widget::ListBar.new parent: s
    bar.add_item("quit", -> { fired += 1; nil }, keys: ["q"])
    s.repaint

    e = emit_kp(s, 'q')
    fired.should eq 1
    e.accepted?.should be_true
  end

  it "leaves a non-matching keypress un-accepted" do
    s = b18_screen
    bar = Crysterm::Widget::ListBar.new parent: s
    bar.add_item("quit", -> { nil }, keys: ["q"])
    s.repaint

    emit_kp(s, 'z').accepted?.should be_false
  end
end

describe "BUGS18 B18-103 ActionBar#items= renumbers auto prefixes" do
  it "reassigns position prefixes when commands are re-added in a new order" do
    s = b18_screen
    bar = Crysterm::Widget::ListBar.new parent: s
    bar.add_item("a", -> { nil })
    bar.add_item("b", -> { nil })
    bar.add_item("c", -> { nil })
    s.repaint
    bar.items.map(&.prefix).should eq ["1", "2", "3"]

    bar.items = bar.items.reverse

    bar.items.map(&.text).should eq ["c", "b", "a"]
    # Auto prefixes must track the raw index (number-key selection routes by
    # it), not the command's previous position.
    bar.items.map(&.prefix).should eq ["1", "2", "3"]
  end

  it "keeps hotkey-derived (non-auto) prefixes across a re-add" do
    s = b18_screen
    bar = Crysterm::Widget::ListBar.new parent: s
    bar.add_item("a", -> { nil })
    bar.add_item("quit", -> { nil }, keys: ["x"])
    s.repaint

    bar.items = bar.items.reverse

    bar.items.map(&.prefix).should eq ["x", "2"]
  end
end

describe "BUGS18 B18-107 ActionBar#activate_item emits ItemActivated" do
  it "emits ItemActivated for a number-key activation, like Enter/click do" do
    s = b18_screen
    fired = 0
    activated = [] of Int32
    bar = Crysterm::Widget::ListBar.new parent: s, keys: true, auto_command_keys: true
    bar.add_item("open", -> { nil })
    bar.add_item("save", -> { fired += 1; nil })
    bar.on(Crysterm::Event::ItemActivated) { |e| activated << e.index }
    s.repaint

    press(bar, '2').accepted?.should be_true
    fired.should eq 1
    activated.should eq [1]
  end

  it "emits ItemActivated from a direct activate_item call" do
    s = b18_screen
    fired = 0
    activated = [] of Int32
    bar = Crysterm::Widget::ListBar.new parent: s
    bar.add_item("open", -> { fired += 1; nil })
    bar.on(Crysterm::Event::ItemActivated) { |e| activated << e.index }
    s.repaint

    bar.activate_item 0
    fired.should eq 1
    activated.should eq [0]
  end
end
