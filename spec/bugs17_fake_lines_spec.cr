require "./spec_helper"

include Crysterm

# BUGS17 B17-04 — the fake-line editors (`insert_line`/`delete_line`/
# `replace_line`/...) stored POST-parse text back into raw `@content`
# (`rebuild_content_from_fake` joined `@_clines.fake`), so any LATER cache-miss
# reparse (width change, resize, scroll, re-attach, style change) re-ran
# `_parse_tags` over already-parsed text: `{open}`/`{close}` output and
# `{escape}` bodies were re-interpreted, dropping escaped braces or turning
# literal tag text into live SGR. The BUGS15 #18 transient-flag fix covered
# only the reparse inside the rebuild itself.
#
# Redesign: the editors splice RAW logical lines (`raw_fake_lines`, raw
# `#content` split at the same boundaries `clean_content_chars` normalizes) and
# rebuild via a NORMAL full reparse (`rebuild_content_from_raw`) — `@content`
# never holds post-parse text, so every later reparse is byte-identical.

# Forces the full reparse a resize/attach would run: invalidates the wrap
# cache's content version so `process_content` re-parses raw `@content`.
private def force_full_reparse(box)
  box._clines.content_version = -1_i64
  box.process_content
end

describe "BUGS17 04: line edits keep raw content authoritative" do
  it "escaped {open}/{close} braces survive insert_line PLUS a later cache-miss reparse" do
    w = Widget::Box.new parent: headless_screen(40, 10), width: 30, height: 5, parse_tags: true
    w.set_content "brace: {open}literal{close}"
    w.rendered_content.should eq "brace: {literal}"

    w.insert_line 0, "header"
    w.rendered_content.should eq "header\nbrace: {literal}"

    # Pre-fix: `@content` now held "header\nbrace: {literal}"; this reparse
    # matched `{literal}` as an unknown tag and dropped it -> "brace: ".
    force_full_reparse(w)
    w.rendered_content.should eq "header\nbrace: {literal}"

    # A genuine width-change reparse (different cache-key miss) too.
    w.width = 20
    w.process_content
    w.rendered_content.should eq "header\nbrace: {literal}"
  end

  it "{escape}-protected literal tag text survives an edit plus reparse" do
    w = Widget::Box.new parent: headless_screen(40, 10), width: 30, height: 5, parse_tags: true
    w.set_content "{escape}{bold}{/escape}"
    w.rendered_content.should eq "{bold}"

    w.insert_line 0, "x"
    w.rendered_content.should eq "x\n{bold}"

    # Pre-fix: the reparse turned the literal "{bold}" into live SGR.
    force_full_reparse(w)
    w.rendered_content.should eq "x\n{bold}"
    w.rendered_content.should_not contain "\e["
  end

  it "keeps raw (un-expanded) source in #content after an edit" do
    w = Widget::Box.new parent: headless_screen(40, 10), width: 30, height: 5, parse_tags: true
    w.set_content "brace: {open}literal{close}"
    w.insert_line 0, "header"

    # The design under test: raw content stays pre-parse source, so repeated
    # reparses start from true raw text.
    w.content.should eq "header\nbrace: {open}literal{close}"
    w.content.should_not contain "\e["
  end

  it "escaped braces survive delete_line and replace_line edits plus reparse" do
    w = Widget::Box.new parent: headless_screen(40, 10), width: 30, height: 5, parse_tags: true
    w.set_content "brace: {open}literal{close}\nsecond\nthird"

    w.delete_line index: 2
    w.replace_line 1, "changed"
    w.rendered_content.should eq "brace: {literal}\nchanged"

    force_full_reparse(w)
    w.rendered_content.should eq "brace: {literal}\nchanged"
  end

  it "still applies tag styling for genuinely tagged content after an edit" do
    ref = Widget::Box.new parent: headless_screen(40, 10), width: 30, height: 5, parse_tags: true
    ref.set_content "{bold}z{/bold}"
    reference_line = ref.rendered_content

    w = Widget::Box.new parent: headless_screen(40, 10), width: 30, height: 5, parse_tags: true
    w.set_content "plain"
    w.insert_line 0, "{bold}z{/bold}"

    lines = w.rendered_content.split('\n')
    lines[0].should eq reference_line
    lines[0].should contain "\e[" # tag became a real SGR sequence
    lines[1].should eq "plain"

    # And the styling is stable across a later full reparse (the raw tag is
    # reparsed, not double-parsed or dropped).
    force_full_reparse(w)
    lines2 = w.rendered_content.split('\n')
    lines2[0].should eq reference_line
    lines2[1].should eq "plain"
  end

  it "keeps never-parsed stray braces literal when an edit introduces the first tag" do
    w = Widget::Box.new parent: headless_screen(40, 10), width: 30, height: 5, parse_tags: true
    # No recognized tag -> `_parse_tags` never ran; the brace renders literally.
    w.set_content "a { b"
    w.rendered_content.should eq "a { b"

    # The edit brings the first real tag, flipping the reparse gate on. The
    # never-parsed brace must keep rendering literally — including after a
    # later full reparse (raw capture escapes it to `{open}`).
    w.append_line "{bold}first{/bold}"
    w.rendered_content.split('\n')[0].should eq "a { b"

    force_full_reparse(w)
    w.rendered_content.split('\n')[0].should eq "a { b"
  end

  it "keeps no_tags (set_text) content literal across an edit plus reparse" do
    w = Widget::Box.new parent: headless_screen(40, 10), width: 30, height: 5
    w.parse_tags = true
    w.set_text "{bold}a{/bold}\nplain"

    w.insert_line 0, "top"
    w.rendered_content.should eq "top\n{bold}a{/bold}\nplain"

    force_full_reparse(w)
    w.rendered_content.should eq "top\n{bold}a{/bold}\nplain"
  end

  # B18-14 regression coverage: the detached-resync semantics must survive the
  # raw-lines redesign — content set while detached is not resurrected by a
  # later fake-splicing edit.
  it "does not resurrect pre-detach content on a detached edit (B18-14)" do
    s = headless_screen(40, 10)
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

  it "escaped braces set while detached survive a detached edit and the attach reparse" do
    s = headless_screen(40, 10)
    w = Widget::Box.new parent: s, width: 20, height: 5, parse_tags: true
    s.repaint
    s.remove w
    w.window?.should be_nil

    w.set_content "brace: {open}literal{close}"
    w.insert_line 0, "header"
    w.content.should eq "header\nbrace: {open}literal{close}"

    s.append w
    s.repaint
    w.rendered_content.should eq "header\nbrace: {literal}"
  end
end
