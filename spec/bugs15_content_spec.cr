require "./spec_helper"

include Crysterm

private def sized_screen(width = 40, height = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false)
end

# BUGS15 #18 — `rebuild_content_from_fake` re-fed `@_clines.fake` (POST-parse
# lines) through `set_content`, running `_parse_tags` a SECOND time. Under the
# drop-malformed policy that silently destroyed escaped literal braces
# (`{open}`/`{close}`) and re-interpreted literal tag-looking text as live SGR,
# on ANY line edit (`insert_line`/`delete_line`/`set_line`/…). Fixed by a
# transient no-reparse flag plus pre-parsing freshly edited lines.
describe "Widget line editors preserve already-parsed content (BUGS15 #18)" do
  it "keeps escaped literal braces after insert_line" do
    w = Widget::Box.new parent: sized_screen, width: 30, height: 5, parse_tags: true
    w.set_content "brace: {open}literal{close}"
    # `{open}`/`{close}` emit literal braces: content renders "brace: {literal}".
    w.get_content.should eq "brace: {literal}"

    w.insert_line 0, "header"
    # Before the fix the second reparse saw "brace: {literal}", matched
    # `{literal}` as an unknown tag and dropped the whole token -> "brace: ".
    w.get_content.should eq "header\nbrace: {literal}"
  end

  it "keeps {escape}-protected literal tag text after insert_line" do
    w = Widget::Box.new parent: sized_screen, width: 30, height: 5, parse_tags: true
    w.set_content "{escape}{bold}{/escape}"
    # `{escape}…{/escape}` emits its body verbatim: renders literal "{bold}".
    w.get_content.should eq "{bold}"

    w.insert_line 0, "x"
    # Before the fix the reparse turned the literal "{bold}" into a live SGR
    # bold escape and the visible text vanished.
    w.get_content.should eq "x\n{bold}"
    w.get_content.should_not contain "\e["
  end

  it "does not corrupt an unrelated escaped-brace row when set_line edits another row" do
    w = Widget::Box.new parent: sized_screen, width: 30, height: 5, parse_tags: true
    w.set_content "brace: {open}literal{close}\nsecond"
    w.get_content.should eq "brace: {literal}\nsecond"

    w.set_line 1, "changed"
    # Editing row 1 must leave row 0's escaped braces intact.
    w.get_content.should eq "brace: {literal}\nchanged"
  end

  it "keeps escaped literal braces after delete_line of another row" do
    w = Widget::Box.new parent: sized_screen, width: 30, height: 5, parse_tags: true
    w.set_content "brace: {open}literal{close}\ndrop me"
    w.delete_line 1
    w.get_content.should eq "brace: {literal}"
  end

  it "still expands a tag in a freshly inserted line (round-trip idempotence)" do
    # A tag in newly inserted text must work exactly as a full set_content would.
    ref = Widget::Box.new parent: sized_screen, width: 30, height: 5, parse_tags: true
    ref.set_content "{bold}z{/bold}"
    reference_line = ref.get_content

    w = Widget::Box.new parent: sized_screen, width: 30, height: 5, parse_tags: true
    w.set_content "plain"
    w.insert_line 0, "{bold}z{/bold}"
    lines = w.get_content.split('\n')
    lines[0].should eq reference_line
    lines[0].should contain "\e[" # became a real SGR sequence
    lines[0].should_not contain "{bold}"
    lines[1].should eq "plain"
  end

  it "keeps no_tags (set_text) content literal across a line edit" do
    w = Widget::Box.new parent: sized_screen, width: 30, height: 5
    w.parse_tags = true
    w.set_text "{bold}a{/bold}\nplain"
    # set_text stores literally; a line edit must not start parsing it.
    w.insert_line 0, "top"
    w.get_content.should eq "top\n{bold}a{/bold}\nplain"
  end
end

# BUGS15 #49 — the hover ToolTip is a satellite window-child bound to the window
# the widget was on at first hover. After reparenting the widget to another
# window the cached tooltip stayed on the OLD window and popped up there. Fixed
# by dropping the stale binding (window mismatch) before reuse, mirroring
# ComboBox#ensure_popup.
private def hover(widget)
  ev = ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None,
    widget.aleft, widget.atop, source: :test)
  widget.emit Crysterm::Event::MouseOver, ev
end

describe "Widget hover tooltip re-homes after a cross-window reparent (BUGS15 #49)" do
  it "creates the tooltip on the widget's current window, not the original one" do
    a = sized_screen
    b = sized_screen

    box = Widget::Box.new parent: a, top: 1, left: 1, width: 10, height: 3
    box.tool_tip = "help"

    hover box
    tip_a = box.@_tooltip
    tip_a.should_not be_nil
    tip_a.not_nil!.window?.should eq a

    # Cross-window reparent (supported via Widget#insert).
    b.append box
    box.window?.should eq b

    hover box
    tip_b = box.@_tooltip
    tip_b.should_not be_nil
    tip_b.not_nil!.window?.should eq b # re-homed to the new window
    # The stale tooltip was destroyed and removed from the old window.
    a.children.includes?(tip_a.not_nil!).should be_false
  end
end
