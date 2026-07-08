require "./spec_helper"

include Crysterm

# BUGS10 #28/#29/#30/#14: the CSS invalidation contract. A rule that stops
# matching reverts what it set (including geometry, which lives on the widget,
# not the `Style`); clearing the stylesheet reverts everything; swapping the
# default (theme) stylesheet at runtime recascades live windows; and a
# recascade mid-transition doesn't orphan the tween.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: w, height: h)
end

# Empties the global default (user-agent) stylesheet for the block, then
# restores it. Must run after the screen exists — window creation auto-installs
# the config-driven theme, which would override an earlier reset.
private def without_default_theme(&)
  saved = Crysterm::CSS.default_stylesheet
  Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
  begin
    yield
  ensure
    Crysterm::CSS.default_stylesheet = saved
  end
end

describe "CSS invalidation" do
  # #28 — geometry declarations bypass `Style`, so they need their own
  # pristine snapshot/restore in the cascade's reset pass.
  it "reverts geometry when its rule stops matching (class removed)" do
    s = headless_screen
    b = Widget::Box.new parent: s, width: "100%"
    b.add_css_class "wide"
    s.stylesheet = ".wide { width: 40; min-width: 12; text-align: center; }"
    s.apply_stylesheet
    b.width.should eq 40
    b.min_width.should eq 12
    b.align.should eq Tput::AlignFlag::HCenter

    b.remove_css_class "wide"
    s.apply_stylesheet
    b.width.should eq "100%"                                        # programmatic value back
    b.min_width.should be_nil                                       # unconstrained again
    b.align.should eq(Tput::AlignFlag::Top | Tput::AlignFlag::Left) # default alignment back
  end

  it "reverts geometry when the stylesheet no longer carries the rule" do
    s = headless_screen
    b = Widget::Box.new parent: s
    s.stylesheet = "Box { width: 40; height: 7; }"
    s.apply_stylesheet
    b.width.should eq 40
    b.height.should eq 7

    s.stylesheet = "Box { color: red; }" # geometry rule gone; cascade still runs
    s.apply_stylesheet
    b.width.should be_nil
    b.height.should be_nil
  end

  # #29 — clearing the stylesheet must restyle (revert) everything, just like
  # assigning one restyles everything; previously the no-active-rules early
  # exit left every widget stuck `css_styled` with the old computed styles.
  it "reverts widgets to pristine when the stylesheet is cleared with no default rules" do
    s = headless_screen
    without_default_theme do
      b = Widget::Button.new
      s.append b
      before_bg = b.styles.normal.bg

      s.stylesheet = "Button { background-color: #ff0000; } Box { width: 33 }"
      s.apply_stylesheet
      b.css_styled?.should be_true
      b.styles.normal.bg.should eq 0xff0000
      b.width.should eq 33

      s.stylesheet = nil
      s.apply_stylesheet
      b.css_styled?.should be_false # inline `@style` short-circuit honored again
      b.styles.normal.bg.should eq before_bg
      b.width.should be_nil # CSS-written geometry reverted too
    end
  end

  it "recascades a stylesheet assigned after a clear" do
    s = headless_screen
    without_default_theme do
      b = Widget::Button.new
      s.append b

      s.stylesheet = "Button { background-color: #ff0000; }"
      s.apply_stylesheet
      s.stylesheet = nil
      s.apply_stylesheet
      b.css_styled?.should be_false

      s.stylesheet = "Button { background-color: #00ff00; }"
      s.apply_stylesheet
      b.css_styled?.should be_true
      b.styles.normal.bg.should eq 0x00ff00
    end
  end

  # #30 — swapping the default (theme) stylesheet at runtime must invalidate
  # existing windows; previously nothing marked them dirty and the
  # document-identity cache swallowed even an explicit restyle.
  it "recascades an existing window when the default stylesheet changes at runtime" do
    s = headless_screen
    b = Widget::Button.new
    s.append b
    saved = Crysterm::CSS.default_stylesheet
    begin
      Crysterm::CSS.default_stylesheet = "Button { color: #ff0000; }"
      s._render
      b.styles.normal.fg.should eq 0xff0000

      # Nothing else marks styling dirty; the generation change alone must.
      Crysterm::CSS.default_stylesheet = "Button { color: #0000ff; }"
      s._render
      b.styles.normal.fg.should eq 0x0000ff
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  # #14 — a full recascade replaces per-state `Style` objects wholesale; an
  # in-flight transition must keep affecting the *live* style, not a captured
  # (now orphaned) one.
  it "keeps a transition tweening the rendered style across a recascade" do
    s = headless_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "btn"
    s.stylesheet = ".btn { background-color: #000000; transition: background-color 0.4s linear; } " \
                   ".btn:hover { background-color: #ffffff; }"
    s._render
    b.style.bg.should eq 0x000000

    b.state = Crysterm::WidgetState::Hovered
    sleep 0.1.seconds # tween under way

    # Force a full recascade mid-tween (what a stylesheet hot-reload or an
    # ancestor-state restyle does) — the per-state Style objects are replaced.
    s.restyle
    s.apply_stylesheet

    sleep 0.1.seconds # ~halfway; ticks must now write the *new* Style
    mid = b.style.bg.not_nil!
    (0x202020 <= mid <= 0xe0e0e0).should be_true # still mid-grey, not snapped to white

    sleep 0.4.seconds
    b.style.bg.should eq 0xffffff # landed on target
  end
end
