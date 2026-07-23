require "./spec_helper"

include Crysterm

# Regression specs for BUGS18 B18-11, B18-13, B18-14, B18-17, B18-18.
# Headless harness mirrors spec/bugs15_scrolling_chrome_spec.cr.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# B18-11 — `_parse_tags` resolved attribute tags via the raising `#window`
# accessor, so every fake-splicing line editor (through `parse_fake_line`)
# crashed with NilAssertionError on a detached widget whenever the new line
# contained a recognized tag — while `process_content`/`append_content`/
# `delete_line` degrade to guarded no-ops in the same state. The fix guards
# `_parse_tags` on attachment; the raw line is stored literally and the
# `Event::Attached` reparse expands it.
describe "BUGS18 11: tagged line edits on a detached widget do not raise" do
  it "no-ops through _parse_tags when detached, and converges on re-attach" do
    s = headless_screen
    box = Widget::Box.new parent: s, width: 20, height: 5, parse_tags: true
    ref = Widget::Box.new parent: s, width: 20, height: 5, parse_tags: true
    s.repaint

    s.remove box
    box.window?.should be_nil

    # Pre-fix: NilAssertionError out of `window.tput._attr` for each of these.
    box.insert_line 0, "{bold}top{/bold}"
    box.append_line "{red-fg}error{/red-fg}"
    box.replace_line 1, "{red-fg}warn{/red-fg}"

    # Same edits on the attached reference widget.
    ref.insert_line 0, "{bold}top{/bold}"
    ref.append_line "{red-fg}error{/red-fg}"
    ref.replace_line 1, "{red-fg}warn{/red-fg}"

    # Re-attach: the Event::Attached reparse expands the literally-stored tags,
    # converging to the state the attached edits produced.
    s.append box
    s.repaint
    box._clines.fake.should eq ref._clines.fake
  end
end

# B18-13 — `scroll_extent_bottom` skipped only `fixed?` children, but the
# border label is `layout_chrome?` (not `fixed`) and is re-glued to
# `@child_base` every frame, so it contributed `child_base + 1` to the extent.
# After a content shrink, `clamp_child_base_to_content` then clamped only to
# `child_base + 1 - visible` instead of the real content maximum, leaving a
# labeled scrollable stuck showing blank space.
describe "BUGS18 13: border label does not inflate scroll_extent_bottom" do
  it "reclamps a labeled scrollable to content after a shrink, like an unlabeled twin" do
    s = headless_screen 40, 14
    content = (1..30).join "\n"
    labeled = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 12,
      scrollable: true, content: content
    labeled.set_label "Output"
    plain = Widget::Box.new parent: s, top: 0, left: 20, width: 20, height: 12,
      scrollable: true, content: content
    s.repaint

    labeled.scroll 100
    plain.scroll 100
    s.repaint # glue the label to the scrolled child_base
    labeled.child_base.should eq plain.child_base
    labeled.child_base.should be > 0

    # Content shrinks below the viewport: both must reclamp straight to 0.
    # Pre-fix the labeled widget clamped only to `child_base + 1 - visible`.
    labeled.set_content (1..5).join "\n"
    plain.set_content (1..5).join "\n"
    plain.child_base.should eq 0
    labeled.child_base.should eq 0
  end
end

# B18-14 — `set_content` on a detached widget updated `@content` but left
# `@_clines.fake` holding the previous content's lines; the fake-splicing
# editors then wrote that stale fake back via `rebuild_content_from_fake`,
# silently destroying the content set while detached. The fix resyncs
# `fake`/`ftor`/`rtof` in `set_content` whenever the widget is detached.
describe "BUGS18 14: detached line edits do not resurrect pre-detach content" do
  it "append_line after a detached set_content keeps the new content" do
    s = headless_screen
    w = Widget::Box.new parent: s, width: 20, height: 5, content: "A\nB"
    s.repaint

    s.remove w
    w.window?.should be_nil
    w.set_content "X\nY"
    w.append_line "Z"
    w.content.should eq "X\nY\nZ"

    # Re-attach renders the detached-set content, not the resurrected old one.
    s.append w
    s.repaint
    w._clines.fake.should eq ["X", "Y", "Z"]
  end

  it "delete_line and replace_line operate on the detached-set content" do
    s = headless_screen
    w = Widget::Box.new parent: s, width: 20, height: 5, content: "one\ntwo\nthree"
    s.repaint
    s.remove w

    w.set_content "alpha\nbeta\ngamma"
    w.delete_line 1, 1
    w.content.should eq "alpha\ngamma"

    w.set_content "cc\ndd"
    w.replace_line 0, "ZZ"
    w.content.should eq "ZZ\ndd"
  end

  it "a multi-line append on a detached widget lands at the end" do
    s = headless_screen
    w = Widget::Box.new parent: s, width: 20, height: 8, content: "A\nB"
    s.repaint
    s.remove w

    # Stale fake had 2 lines; the new content has 5 — the append must land at
    # index 5, not at the stale index 2.
    w.set_content "v\nw\nx\ny\nz"
    w.append_line "Z"
    w.content.should eq "v\nw\nx\ny\nz\nZ"
  end

  it "line edits on an empty detached widget behave like attached ones" do
    s = headless_screen
    w = Widget::Box.new parent: s, width: 20, height: 5, content: "seed"
    s.repaint
    s.remove w

    w.set_content ""
    w.append_line "first"
    w.content.should eq "first"
  end
end

# B18-17 — the wrap cache key omitted the style inputs baked into the wrapped
# line text (`tab_size`/`tab_char` TAB expansion, `fill_char` alignment
# padding), so the documented `mark_dirty`/`update` protocol after a direct
# style mutation (or a CSS cascade change) never re-expanded tabs or re-padded
# aligned lines. The fix folds the three values into the cache key.
describe "BUGS18 17: wrap cache invalidates on tab/fill style changes" do
  it "re-expands tabs after style.tab_size changes with the update protocol" do
    s = headless_screen
    w = Widget::Box.new parent: s, width: 30, height: 3, content: "a\tb"
    s.repaint
    w._clines.lines[0].should eq "a    b" # default tab_size 4

    w.style.tab_size = 8
    w.update
    s.repaint
    w._clines.lines[0].should eq "a        b"
  end

  it "re-pads aligned lines after style.fill_char changes" do
    s = headless_screen
    w = Widget::Box.new parent: s, width: 10, height: 3, content: "ab"
    w.align = Tput::AlignFlag::HCenter
    s.repaint
    w._clines.lines[0].should contain "ab"
    w._clines.lines[0].should_not contain "."

    w.style.fill_char = '.'
    w.update
    s.repaint
    w._clines.lines[0].should contain "."
  end
end

# B18-18 — the horizontal scroll base had no content-change reclamp (sibling
# gap of the vertical ContentParsed reclamp): after content narrowed while
# scrolled right, `@child_base_x` stayed past `scroll_width` and every line
# sliced to "", leaving a blank viewport until a manual horizontal scroll.
# The fix adds a change-guarded horizontal clamp (+ mark_dirty) to
# `clamp_child_base_to_content`.
describe "BUGS18 18: horizontal base reclamps when content narrows" do
  it "pulls child_base_x back into range and repaints non-empty rows" do
    s = headless_screen
    w = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5,
      scrollable: true
    w.wrap_content = false
    w.set_content Array.new(3) { |i| "line#{i}" + "x" * 94 }.join "\n"
    s.repaint

    w.scroll_by_x 40
    w.child_base_x.should eq 40
    s.repaint
    w._clines.lines[0].should_not eq ""

    # Content narrows below the old base: the ContentParsed reclamp must pull
    # child_base_x back (pre-fix it stayed at 40 and every row sliced to "").
    w.set_content (1..3).map { |i| "short#{i}" }.join "\n"
    w.child_base_x.should eq 0
    s.repaint
    s.repaint # healing frame scheduled by the clamp's mark_dirty
    w._clines.lines[0].should eq "short1"
  end
end
