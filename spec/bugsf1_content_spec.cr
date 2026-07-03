require "./spec_helper"

include Crysterm

# Regression coverage for BUGS-F1 findings 32-35 in `src/widget_content.cr`.

private def sized_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "Widget#delete_line on content seeded before attach (finding 32)" do
  it "does not raise IndexError when `ftor` is still empty" do
    # Detached widget (no window): `push_line` fills `@_clines.fake` directly, but
    # `process_content` bails (`return false unless window?`), so `ftor` stays
    # empty even though `fake` is not.
    w = Widget::Box.new
    w.window = nil
    w.window?.should be_nil

    w.push_line "x"
    w._clines.fake.should eq ["x"]
    w._clines.ftor.empty?.should be_true

    # Before the fix this raised `IndexError` reading `@_clines.ftor[i][0]`.
    w.delete_line

    w.get_content.should eq ""
  end
end

describe "Widget#append_content alignment-tag carry (finding 33)" do
  it "keeps alignment carried by an unclosed opener when pushing a line" do
    s = sized_screen

    box = Widget::Box.new(
      parent: s, top: 0, left: 0, width: 20, height: 6, parse_tags: true)
    box.set_content "{center}Title"
    s._render

    box.push_line "subtitle"

    # Ground truth: a full reparse of the identical total content centers the
    # appended line because the unclosed `{center}` carries its alignment.
    ref = Widget::Box.new(
      parent: s, top: 6, left: 0, width: 20, height: 6, parse_tags: true)
    ref.set_content "{center}Title\nsubtitle"
    s._render

    box._clines.lines.map(&.to_s).should eq ref._clines.lines.map(&.to_s)

    # And concretely: the appended "subtitle" row is centered (leading pad),
    # not left-aligned as the fast path produced before the fix.
    sub = box._clines.lines.find(&.includes?("subtitle"))
    sub.should start_with(" ")
    sub.strip.should eq "subtitle"
  end
end

describe "Widget#insert_bottom / #delete_bottom vs horizontal scrollbar (finding 34)" do
  it "insert_bottom targets the visible bottom, above the hscrollbar row" do
    s = sized_screen

    box = Widget::Box.new(
      parent: s, top: 0, left: 0, width: 10, height: 5,
      scrollable: true, wrap_content: false,
      horizontal_scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AlwaysOn,
      content: "L0\nL1\nL2\nL3\nL4\nL5")
    s._render

    box.hscrollbar_rows.should eq 1

    box.insert_bottom "NEW"

    lines = box.get_lines
    lines.size.should eq 7
    # visible_content_rows = aheight(5) - iheight(0) - hscrollbar(1) = 4, so the
    # insert lands at fake index 4, not 5 (the pre-fix `aheight - iheight`).
    lines[4].should eq "NEW"
  end

  it "delete_bottom removes the visible bottom row, above the hscrollbar row" do
    s = sized_screen

    box = Widget::Box.new(
      parent: s, top: 0, left: 0, width: 10, height: 5,
      scrollable: true, wrap_content: false,
      horizontal_scrollbar_policy: Crysterm::Widget::ScrollBarPolicy::AlwaysOn,
      content: "L0\nL1\nL2\nL3\nL4\nL5")
    s._render

    box.delete_bottom 1

    # Deletes fake index 3 ("L3"), the visible bottom given the reserved row —
    # not "L4" as the pre-fix formula did.
    box.get_lines.should eq ["L0", "L1", "L2", "L4", "L5"]
  end
end

describe "Runtime align/wrap_content/parse_tags invalidate the wrap cache (finding 35)" do
  it "reparses when `align` changes on a rendered widget" do
    s = sized_screen

    box = Widget::Box.new(
      parent: s, top: 0, left: 0, width: 20, height: 3, content: "Hi")
    s._render
    box._clines.lines[0].should eq "Hi"

    box.align = Tput::AlignFlag::Center
    box.process_content

    line = box._clines.lines[0]
    line.strip.should eq "Hi"
    line.should start_with(" ")
    line.size.should eq 20
  end

  it "reparses when `parse_tags` is toggled on" do
    s = sized_screen

    box = Widget::Box.new(
      parent: s, top: 0, left: 0, width: 20, height: 3,
      content: "{bold}Hi{/bold}", parse_tags: false)
    s._render
    box._clines.lines[0].should eq "{bold}Hi{/bold}"

    box.parse_tags = true
    box.process_content

    box._clines.lines[0].includes?("{bold}").should be_false
  end

  it "reparses when `wrap_content` is toggled off" do
    s = sized_screen

    box = Widget::Box.new(
      parent: s, top: 0, left: 0, width: 6, height: 5,
      content: "aaaa bbbb cccc", wrap_content: true)
    s._render
    (box._clines.lines.size > 1).should be_true

    box.wrap_content = false
    box.process_content

    box._clines.lines.size.should eq 1
  end
end
