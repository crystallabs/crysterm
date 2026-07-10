require "./spec_helper"

include Crysterm

# Regression specs for the BUGS13 "Widget top-level" content findings:
#
# * W6 — `process_content`'s wrap-convergence loop no longer seeds its margin
#   from the PREVIOUS wrap's line count (`_wrap_content` used to read
#   `content_margin_x` before the outbuf reset): pass 1 wraps against the
#   empty-lines margin (`content_margin_x_empty`, preserving `AlwaysOn`),
#   pass 2 against pass 1's fresh margin. Pre-fix, bistable content latched
#   the with-bar layout depending on resize history.
# * W16 — `@_content_version` / `CLines#content_version` widened to `Int64`
#   in lockstep, so a long-lived appending widget can't hit `Int32::MAX`'s
#   checked-add OverflowError.
# * W17 — `_parse_tags`' `{/escape}` closer regex body group is optional
#   (`[\s\S]*?`), so an EMPTY `{escape}{/escape}` pair parses instead of
#   falling into the unterminated-escape bail that dumped the remainder
#   verbatim (literal `{/escape}` on screen, later tags unparsed).

private def content_screen(w = 40, h = 20)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: w, height: h, default_quit_keys: false)
end

private def wrapped_lines(widget)
  widget._clines.lines.map(&.to_s)
end

# `@_content_version` has no public accessor; expose it for W16.
private class VersionProbe < Crysterm::Widget::Box
  def version_peek : Int64
    @_content_version
  end

  def version_poke(v : Int64) : Nil
    @_content_version = v
  end
end

describe "BUGS13 W6: AsNeeded scrollbar margin isn't seeded from the stale wrap" do
  it "a width round-trip converges back to the fresh no-bar layout" do
    s = content_screen
    # Interior width 12, viewport 9 rows. Eight 12-column lines fit exactly
    # without a bar; at width 11 each wraps to two (16 lines) and the bar
    # shows.
    text = Array.new(8) { "x" * 12 }.join('\n')
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 12, height: 9,
      scrollable: true, scrollbar_policy: Widget::ScrollBarPolicy::AsNeeded
    box.content = text
    box.process_content
    box.content_margin_x.should eq 0
    wrapped_lines(box).size.should eq 8

    # Narrow: overflow, bar on.
    box.width = 11
    box.process_content
    box.content_margin_x.should eq 1
    wrapped_lines(box).size.should eq 16

    # Back to the original width. Pre-fix, pass 1 seeded the margin from the
    # previous 16-line wrap, so the content stayed wrapped at 11 columns and
    # the bar latched forever (16 lines + bar); a fresh identical widget
    # shows 8 lines and no bar.
    box.width = 12
    box.process_content

    ref = Widget::Box.new parent: s, top: 0, left: 20, width: 12, height: 9,
      scrollable: true, scrollbar_policy: Widget::ScrollBarPolicy::AsNeeded
    ref.content = text
    ref.process_content

    ref.content_margin_x.should eq 0
    wrapped_lines(ref).size.should eq 8
    box.content_margin_x.should eq ref.content_margin_x
    wrapped_lines(box).should eq wrapped_lines(ref)
  end

  it "AlwaysOn keeps its reservation through the empty-lines seed" do
    s = content_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 12, height: 9,
      scrollable: true, scrollbar_policy: Widget::ScrollBarPolicy::AlwaysOn
    box.content = "y" * 12
    box.process_content
    # Pass 1 must reserve the bar column even though no lines exist yet
    # (content_margin_x_empty is scrollbar_width for AlwaysOn), so the
    # 12-column line wraps against 11 columns right away.
    box.content_margin_x.should eq 1
    wrapped_lines(box).should eq ["y" * 11, "y"]
  end
end

describe "BUGS13 W16: content version is Int64 (no Int32::MAX overflow)" do
  it "bumps past Int32::MAX without raising and still invalidates the cache" do
    s = content_screen
    w = VersionProbe.new parent: s, top: 0, left: 0, width: 10, height: 3
    w.content = "one"
    w.process_content
    wrapped_lines(w).should eq ["one"]

    big = Int32::MAX.to_i64 + 5
    w.version_poke big
    # Keep the wrap cache keyed as current for the poked version (integer
    # autocast doesn't survive CLines' forward_missing_to, hence no bare
    # literal here).
    w._clines.content_version = big

    # The version bump in set_content must not raise (pre-widening this was a
    # checked Int32 `+= 1` at MAX+…), and the mismatch must reparse.
    w.content = "two"
    w.version_peek.should eq big + 1
    w._clines.content_version.should eq big + 1
    wrapped_lines(w).should eq ["two"]
  end

  it "append_content keeps bumping in Int64 territory" do
    s = content_screen
    w = VersionProbe.new parent: s, top: 0, left: 0, width: 10, height: 5
    w.content = "one"
    w.process_content
    big = Int32::MAX.to_i64 + 7
    w.version_poke big
    w._clines.content_version = big

    w.push_line "two"
    w.version_peek.should be > big
    w.pcontent.should contain "two"
  end
end

describe "BUGS13 W17: empty {escape}{/escape} does not corrupt the remainder" do
  it "parses content after an empty escape pair (later tags still work)" do
    s = content_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3,
      parse_tags: true
    box.content = "a{escape}{/escape}b{bold}c{/bold}"
    box.process_content
    joined = wrapped_lines(box).join
    joined.should_not contain "{/escape}"
    joined.should_not contain "{bold}"
    joined.should contain "ab"
    # The later {bold} tag parsed to SGR instead of being dumped verbatim.
    joined.should contain "\e["
  end

  it "renders the characters around the empty pair, with the tag applied" do
    s = content_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 1,
      parse_tags: true
    box.content = "a{escape}{/escape}b{bold}c{/bold}"
    s._render
    (0..2).map { |x| s.lines[0][x].char }.join.should eq "abc"
    # 'c' carries the bold attr; 'b' doesn't.
    s.lines[0][2].attr.should_not eq s.lines[0][1].attr
  ensure
    s.try &.destroy
  end

  it "the untrusted-empty interpolation idiom yields just the surroundings" do
    s = content_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3,
      parse_tags: true
    untrusted = ""
    box.content = "x{escape}#{untrusted}{/escape}y"
    box.process_content
    wrapped_lines(box).should eq ["xy"]
  end

  it "a non-empty escape body still passes through verbatim" do
    s = content_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3,
      parse_tags: true
    box.content = "x{escape}{bold}{/escape}y"
    box.process_content
    joined = wrapped_lines(box).join
    joined.should contain "x{bold}y"
    joined.should_not contain "\e["
  end
end
