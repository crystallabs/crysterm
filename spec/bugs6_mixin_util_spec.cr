require "./spec_helper"

include Crysterm

# Regression specs for BUGS6 section 3 "Mixin Layer & Misc Utilities".
#
#  BUG 1 (fixed in src/mixin/interactive.cr): paging (Ctrl-U/D/B/F) and
#     jump-to-edge (g/G) were all gated behind `@vi`, and PageUp/PageDown/Home/
#     End were never bound at all. A `keys: true, vi: false` widget (e.g.
#     PlainTextEdit) therefore had no half/full-page scroll and no jump keys.
#     Paging + PageUp/PageDown + Home/End are now bound unconditionally
#     (matching ScrollableBox#on_keypress); only k/j/g/G stay vi-gated.
#
#  BUG 2 (fixed in src/misc/util/unicode.cr): `display_width`'s ASCII fast path
#     used `ascii_only?`, which is true for C0 controls (TAB/CR/ESC) and DEL —
#     counting them as width 1, contradicting `codepoint_width` (0). The fast
#     path now only fires for fully printable-ASCII strings (0x20..0x7E).
#
#  BUG 3 (fixed in src/mixin/instances.cr): `global(create: false)` did
#     `(... || nil).not_nil!`, raising on an empty list instead of returning
#     nil. The nilable query path no longer asserts non-nil.
#
#  BUG 4 (documented in src/mixin/children.cr): `insert` (and append/prepend/
#     insert_before/insert_after) is a deliberate no-op when the element is
#     already a child — it does not reposition. This spec pins that behavior.

# --- BUG 1 fixtures -----------------------------------------------------------

# A widget whose *only* keyboard behavior comes from Mixin::Interactive (unlike
# PlainTextEdit, whose TextEditing mixin also handles arrows/paging for the
# caret). This isolates the mixin's viewport-scroll bindings.
private class BugsInteractiveBox < Crysterm::Widget::Box
  include Crysterm::Mixin::Interactive
  @scrollable = true
  @always_scroll = true
end

private def bugs6_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def bugs6_long_content
  String.build { |s| 50.times { |i| s << "Line " << i << '\n' } }
end

private def bugs6_widget(vi = false)
  s = bugs6_screen
  w = BugsInteractiveBox.new(
    parent: s, content: bugs6_long_content,
    keys: true, vi: vi, top: 0, left: 0, width: 20, height: 10)
  s.render
  {s, w}
end

private def press(w, ch : Char = '\0', key : Tput::Key? = nil)
  w.emit Crysterm::Event::KeyPress.new(ch, key)
end

# --- BUG 3 fixture ------------------------------------------------------------

private class BugsInstanceThing
  include Crysterm::Mixin::Instances

  def initialize
    register_instance
  end
end

describe "BUGS6 Interactive mixin scroll keys (bug 1)" do
  it "PageDown / PageUp scroll a full page even with vi: false" do
    _, w = bugs6_widget vi: false
    w.scroll_position.should eq 0

    press w, key: Tput::Key::PageDown
    down = w.scroll_position
    down.should be > 0

    press w, key: Tput::Key::PageUp
    w.scroll_position.should be < down
  end

  it "Home / End jump to top / bottom even with vi: false" do
    _, w = bugs6_widget vi: false

    press w, key: Tput::Key::End
    w.scroll_position.should be > 0

    press w, key: Tput::Key::Home
    w.scroll_position.should eq 0
  end

  it "Ctrl-D (half page) and Ctrl-F (full page) scroll with vi: false" do
    _, w = bugs6_widget vi: false

    press w, key: Tput::Key::CtrlD
    half = w.scroll_position
    half.should be > 0

    press w, key: Tput::Key::Home
    press w, key: Tput::Key::CtrlF
    w.scroll_position.should be >= half # a full page is at least as far as a half page
  end

  it "vi single-char j/k and g/G work only with vi: true" do
    _, off = bugs6_widget vi: false
    press off, ch: 'j'
    off.scroll_position.should eq 0 # 'j' is inert without vi

    _, on = bugs6_widget vi: true
    press on, ch: 'j'
    on.scroll_position.should be > 0

    press on, ch: 'G'
    bottom = on.scroll_position
    bottom.should be > 0
    press on, ch: 'g'
    on.scroll_position.should eq 0
  end
end

describe "BUGS6 Unicode.display_width control-char fast path (bug 2)" do
  it "counts a TAB as 0 columns, consistent with codepoint_width" do
    Crysterm::Unicode.display_width("a\tb").should eq 2
    Crysterm::Unicode.codepoint_width('\t').should eq 0
  end

  it "counts a bare ESC / CR as 0 columns" do
    Crysterm::Unicode.display_width("a\eb").should eq 2
    Crysterm::Unicode.display_width("a\rb").should eq 2
  end

  it "still fast-paths printable-ASCII strings to their byte length" do
    Crysterm::Unicode.display_width("hello").should eq 5
    Crysterm::Unicode.display_width("").should eq 0
  end
end

describe "BUGS6 Instances.global? (bug 3)" do
  it "returns nil on an empty list instead of raising" do
    BugsInstanceThing.instances.clear
    BugsInstanceThing.global?.should be_nil
  end

  it "returns the most recent existing instance when present" do
    BugsInstanceThing.instances.clear
    BugsInstanceThing.new # an earlier instance; `global` must return the LATER one
    b = BugsInstanceThing.new
    BugsInstanceThing.global?.should be b
  end

  it "still creates a non-nil instance on the default create path" do
    BugsInstanceThing.instances.clear
    BugsInstanceThing.global.should_not be_nil
  end
end

describe "BUGS6 Children#insert on an existing child (bug 4 — not present at widget level)" do
  # BUGS6 §3 bug 4 read the bare `Mixin::Children#insert`, whose `@children_set`
  # guard makes a re-insert a no-op. But every real widget goes through
  # `Widget#insert`/`Window#insert`, which override the mixin to detach `element`
  # from its current parent first and then call `super`. So on an actual widget a
  # re-insert *does* reposition (remove-then-add) — there is no repositioning bug.
  it "repositions an existing child instead of no-op'ing, with no duplicate" do
    s = bugs6_screen
    parent = Crysterm::Widget::Box.new parent: s, width: 10, height: 10
    a = Crysterm::Widget::Box.new parent: parent
    b = Crysterm::Widget::Box.new parent: parent

    parent.children.should eq [a, b]

    # Re-inserting b at the front moves it there (DOM-like), no duplicate.
    parent.insert(b, 0)
    parent.children.should eq [b, a]
    parent.children.size.should eq 2

    # append moves an existing child back to the end.
    parent.append b
    parent.children.should eq [a, b]
    parent.children.size.should eq 2
  end
end
