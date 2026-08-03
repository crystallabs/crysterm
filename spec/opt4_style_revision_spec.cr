require "./spec_helper"

include Crysterm

# O4-12: `Style#attr_revision` (the style-mutation version counter over
# `style_to_attr`'s read set) and the `{identity, revision, stamped default}`
# memo gating the `style_to_attr` recompute on `process_content`'s cache-hit
# path (`src/widget_content_wrap.cr`).

# A window at the unstyled floor (no theme), where inline `@style` wins
# wholesale — so `style =` swaps below resolve to exactly the assigned object.
private def floor_screen
  s = headless_screen(default_quit_keys: true)
  Crysterm::CSS.theme = nil
  s
end

# The active theme / default stylesheet is process-global; restore around each
# example so floor examples can't leak into later specs.
private def with_saved_theme(&)
  saved_theme = Crysterm::CSS.theme
  saved_default = Crysterm::CSS.default_stylesheet
  yield
ensure
  Crysterm::CSS.theme = saved_theme
  Crysterm::CSS.default_stylesheet = saved_default.not_nil!
end

describe "Style#attr_revision" do
  it "bumps on every setter in style_to_attr's read set" do
    s = Style.new
    r = s.attr_revision
    s.fg = 0x112233
    s.attr_revision.should be > r

    r = s.attr_revision
    s.bg = "#445566"
    s.attr_revision.should be > r

    # The Nil overload (clearing a color) is a mutation too.
    r = s.attr_revision
    s.fg = nil
    s.attr_revision.should be > r

    {% for attr in %w[bold italic underline blink reverse strike visible] %}
      r = s.attr_revision
      s.{{ attr.id }} = true
      s.attr_revision.should be > r
    {% end %}
  end

  it "bumps even when re-assigning the same value (over-invalidation is safe)" do
    s = Style.new
    s.bold = true
    r = s.attr_revision
    s.bold = true
    s.attr_revision.should be > r
    r = s.attr_revision
    s.bg = 0x102030
    s.attr_revision.should be > r
    s.bg = 0x102030
    s.attr_revision.should be > r
  end

  it "does not bump on reads or attr-irrelevant mutations" do
    s = Style.new
    r = s.attr_revision
    s.bold?
    s.visible?
    s.fg
    s.bg
    s.attr_revision.should eq r

    # Outside `style_to_attr`'s read set — box sub-objects, tint, opacity,
    # TAB/fill knobs — mutations must not invalidate the attr memo.
    s.border = true
    s.padding = 1
    s.margin = 1
    s.shadow = true
    s.tint = 0x334455
    s.opacity = 0.5
    s.tab_size = 8
    s.tab_char = "."
    s.fill_char = '.'
    s.attr_revision.should eq r
  end
end

describe "process_content cache-hit attr memo (O4-12)" do
  it "in-place style mutation still refreshes the cached attr (CopperBar case)" do
    s = headless_screen(default_quit_keys: true)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3,
      content: "Hi"
    s.repaint

    before = box._clines.attr.not_nil![0]

    # The CopperBar idiom: mutate the resolved style in place — no object swap.
    box.style.bg = 0x102030
    # Content unchanged, so this is the cache-hit path; the revision bump must
    # defeat the memo and re-derive the base attr.
    box.process_content.should be_false

    after = box._clines.attr.not_nil![0]
    after.should_not eq before
    after.should eq Widget.style_to_attr(box.style)
    box.process_content.should be_false
    box._clines.attr.not_nil![0].should eq after
  end

  it "keeps the attr stable and current across unchanged repeat processing" do
    s = headless_screen(default_quit_keys: true)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3,
      content: "Hi", style: Style.new(bg: 0x223344)
    s.repaint

    expected = Widget.style_to_attr(box.style)
    3.times do
      box.process_content.should be_false
      box._clines.attr.not_nil![0].should eq expected
    end
  end

  it "a swapped style object invalidates by identity even at an equal revision" do
    with_saved_theme do
      s = floor_screen
      a = Style.new(bg: 0x111111)
      b = Style.new(bg: 0x222222)
      box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3,
        content: "Hi", style: a
      s.repaint
      # Stamp the memo on a cache-hit pass, then align `b`'s counter with `a`'s
      # via same-value re-assignments so only object identity distinguishes them.
      box.process_content.should be_false
      while b.attr_revision < a.attr_revision
        b.bg = 0x222222
      end
      b.attr_revision.should eq a.attr_revision

      box.style = b
      box.process_content.should be_false
      box._clines.attr.not_nil![0].should eq Widget.style_to_attr(b)
    end
  end

  it "swap away, reparse, swap back refreshes despite unchanged identity+revision" do
    with_saved_theme do
      s = floor_screen
      a = Style.new(bg: 0x111111)
      b = Style.new(bg: 0x222222)
      box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3,
        content: "Hi", style: a
      s.repaint
      # Stamp the memo against `a`.
      box.process_content.should be_false
      rev = a.attr_revision

      # Swap to `b` and reparse under it: `_parse_attr` rewrites
      # `@_parse_attr_default` to `b`'s attr without touching the memo key.
      box.style = b
      box.set_content "Yo"

      # Swap back: same object, same revision — the stamped-default third of
      # the memo key must still force a re-derive, or the widget keeps `b`'s
      # background.
      box.style = a
      a.attr_revision.should eq rev
      box.process_content.should be_false
      box._clines.attr.not_nil![0].should eq Widget.style_to_attr(a)
    end
  end
end
