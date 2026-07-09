require "./spec_helper"

include Crysterm

# Regression coverage for BUGS12 findings 21-22 in `src/widget_content.cr`
# (`append_content`'s fast path vs. a full reparse of the same content).

private def sized_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

private def make_box(s, parse_tags = false, top = 0)
  Widget::Box.new(parent: s, top: top, left: 0, width: 40, height: 8, parse_tags: parse_tags)
end

# Forces the full reparse a resize would run: invalidates the wrap cache's
# content version so `process_content` re-parses raw `@content` from scratch.
private def force_full_reparse(box)
  box._clines.content_version = -1
  box.process_content
end

describe "Widget#append_content nested closing tags (BUGS12 finding 21)" do
  it "renders identically before and after a full reparse when a closer pops a carried tag" do
    s = sized_screen
    box = make_box(s, parse_tags: true)
    # Two unclosed openers: a full reparse's fg stack is [red, blue] at the
    # append boundary. Before the fix, the fast path parsed the pushed line
    # standalone (empty stack), emitting the default-fg off-SGR, while a resize's
    # full reparse popped blue and restored red — same content, different bytes.
    box.set_content "{red-fg}{blue-fg}a"
    box.process_content

    box.push_line "{/blue-fg}b"
    lines_after_push = box._clines.lines.map(&.to_s)

    force_full_reparse(box)
    box._clines.lines.map(&.to_s).should eq lines_after_push
  end

  it "renders identically across a reparse when a balanced closer pops to a carried same-category tag" do
    s = sized_screen
    box = make_box(s, parse_tags: true)
    # `{/bold}` is balanced *within* the segment, but with `{bold}` still open
    # from existing content, a full reparse's pop restores `{bold}` (`\e[1m`)
    # where the standalone parse emitted the off-SGR (`\e[22m`).
    box.set_content "{bold}a"
    box.process_content

    box.push_line "{bold}x{/bold}"
    lines_after_push = box._clines.lines.map(&.to_s)

    force_full_reparse(box)
    box._clines.lines.map(&.to_s).should eq lines_after_push
  end

  it "keeps a stray brace in an appended segment consistent with a full reparse" do
    s = sized_screen
    box = make_box(s, parse_tags: true)
    # Existing content has tags, so a full reparse tag-parses the whole string
    # and drops the appended stray `{` (drop-malformed policy). The fast path
    # must apply the same parse to the segment even though it matches no tag.
    box.set_content "{red-fg}a{/red-fg}"
    box.process_content

    box.push_line "x { y"
    lines_after_push = box._clines.lines.map(&.to_s)
    lines_after_push[1].should eq "x  y"

    force_full_reparse(box)
    box._clines.lines.map(&.to_s).should eq lines_after_push
  end
end

describe "Widget#append_content content-shape flags (BUGS12 finding 22)" do
  it "parses tags appended while parse_tags was off after a later parse_tags = true flip" do
    s = sized_screen
    box = make_box(s)
    box.parse_tags?.should be_false
    box.set_content "hello"
    box.process_content
    box.push_line "{bold}world"

    # Literal while parsing is off, like a set_content of the same string.
    force_full_reparse(box)
    box._clines.lines.map(&.to_s).should eq ["hello", "{bold}world"]

    # The supported runtime flip must reparse the appended tag too. Before the
    # fix, `@_content_has_tags` stayed false (the append gated it on
    # `@parse_tags`), so the reparse skipped `_parse_tags` and the tag stayed
    # literal permanently.
    box.parse_tags = true
    box.process_content

    ref = make_box(s, parse_tags: true, top: 8)
    ref.set_content "hello\n{bold}world"
    ref.process_content

    box._clines.lines.map(&.to_s).should eq ref._clines.lines.map(&.to_s)
  end

  it "honors an align tag appended while parse_tags was off after a flip, like set_content" do
    s = sized_screen
    box = make_box(s)
    box.set_content "hello"
    box.process_content
    box.push_line "{center}mid{/center}"

    box.parse_tags = true
    box.process_content

    ref = make_box(s, parse_tags: true, top: 8)
    ref.set_content "hello\n{center}mid{/center}"
    ref.process_content

    box._clines.lines.map(&.to_s).should eq ref._clines.lines.map(&.to_s)

    # And the align flag must now be live for the *next* append's bail decision:
    # an unclosed-alignment carry across a later push must match set_content.
    box.push_line "tail"
    ref2 = make_box(s, parse_tags: true, top: 16)
    ref2.set_content "hello\n{center}mid{/center}\ntail"
    ref2.process_content
    box._clines.lines.map(&.to_s).should eq ref2._clines.lines.map(&.to_s)
  end

  it "appends an align-tagged line like set_content when parse_tags is on" do
    s = sized_screen
    box = make_box(s, parse_tags: true)
    box.set_content "hello"
    box.process_content
    box.push_line "{center}mid"
    box.push_line "still centered"

    ref = make_box(s, parse_tags: true, top: 8)
    ref.set_content "hello\n{center}mid\nstill centered"
    ref.process_content

    box._clines.lines.map(&.to_s).should eq ref._clines.lines.map(&.to_s)
  end
end

describe "Widget#append_content fast path retention" do
  it "still takes the fast path for plain-text appends" do
    s = sized_screen
    box = make_box(s)
    box.set_content "hello"
    box.process_content

    box.append_content("world").should be_true
    # Fast-path signature: the joined pcontent is deferred (nil), not rebuilt.
    box._pcontent.should be_nil
    box.content.should eq "hello\nworld"
  end

  it "still takes the fast path for balanced tagged appends (the tagged-log case)" do
    s = sized_screen
    box = make_box(s, parse_tags: true)
    box.set_content "{green-fg}[INFO]{/green-fg} start"
    box.process_content

    # Balanced tags leave no open state at the boundary, so standalone parsing
    # stays byte-identical to a full reparse — no bail.
    box.append_content("{green-fg}[INFO]{/green-fg} more {bold}stuff{/bold}").should be_true

    lines_after_push = box._clines.lines.map(&.to_s)
    force_full_reparse(box)
    box._clines.lines.map(&.to_s).should eq lines_after_push
  end

  it "stays fast for plain appends after an unclosed opener (attr carry, no tag parse)" do
    s = sized_screen
    box = make_box(s, parse_tags: true)
    box.set_content "{red-fg}opens red"
    box.process_content

    box.append_content("still red").should be_true

    lines_after_push = box._clines.lines.map(&.to_s)
    attrs_after_push = box._clines.attr.not_nil!.dup
    force_full_reparse(box)
    box._clines.lines.map(&.to_s).should eq lines_after_push
    box._clines.attr.should eq attrs_after_push
  end

  it "bails once when tags first arrive, then resumes the fast path" do
    s = sized_screen
    box = make_box(s, parse_tags: true)
    box.set_content "plain"
    box.process_content

    # First tagged segment over never-parsed content: bail (a reparse would now
    # tag-parse the existing raw content too).
    box.append_content("{bold}first{/bold}").should be_false
    box.push_line "{bold}first{/bold}"

    # Tag regime is established (and balanced), so appends are fast again.
    box.append_content("{bold}second{/bold}").should be_true

    lines_after_push = box._clines.lines.map(&.to_s)
    force_full_reparse(box)
    box._clines.lines.map(&.to_s).should eq lines_after_push
  end
end
