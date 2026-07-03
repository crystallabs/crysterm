require "./spec_helper"

include Crysterm

# Invalidation contract of the frame-memoized style resolution
# (`Mixin::Style#style` + `Widget#frame_insets` + the `_minimal_rectangle`
# frame memo — see PERF.md 1.1/1.2/2.4). The caches are stamped by
# `Window#renders` and invalidated eagerly by `#state=`, `#style=`, `#styles=`,
# `#css_styled=` (the cascade) and `#mark_dirty`, so every externally-visible
# change must be reflected no later than the next render — and same-frame for
# the eager hooks.

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# A window at the unstyled floor (no theme, empty default stylesheet), where
# `#style` semantics are purely programmatic: inline `@style` wins wholesale
# and the floor highlight fallbacks are live. See `unstyled_floor_spec.cr`.
private def floor_screen
  s = headless_screen
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

describe "frame-memoized style" do
  it "returns the same resolved object within one frame" do
    s = headless_screen
    w = Widget::Box.new parent: s, width: 10, height: 3
    s._render
    w.style.should be w.style
  end

  it "reflects a state change immediately (focused floor button gains reverse)" do
    with_saved_theme do
      s = floor_screen
      btn = Widget::Button.new parent: s, top: 0, left: 0, content: "OK"
      s.apply_stylesheet
      s._render
      # Auto-focus may have focused the button on first render; normalize, and
      # exercise the invalidation in both directions with no render between.
      btn.state = WidgetState::Normal
      btn.style.reverse?.should be_falsey
      btn.state = WidgetState::Focused
      btn.style.reverse?.should be_true
      btn.state = WidgetState::Normal
      btn.style.reverse?.should be_falsey
    end
  end

  it "reflects an inline style= swap immediately (floor)" do
    with_saved_theme do
      s = floor_screen
      w = Widget::Box.new parent: s, width: 10, height: 3,
        style: Style.new(fg: 0x112233)
      s.apply_stylesheet
      s._render
      w.style.fg.should eq 0x112233
      w.style = Style.new(fg: 0x445566)
      w.style.fg.should eq 0x445566
    end
  end

  it "reflects a styles= swap immediately (floor)" do
    with_saved_theme do
      s = floor_screen
      w = Widget::Box.new parent: s, width: 10, height: 3
      s.apply_stylesheet
      s._render
      w.style # prime the memo
      w.styles = Styles.new normal: Style.new(fg: 0x778899)
      w.style.fg.should eq 0x778899
    end
  end

  it "picks up direct field mutation of the backing style by the next frame" do
    with_saved_theme do
      s = floor_screen
      w = Widget::Box.new parent: s, width: 10, height: 3
      s.apply_stylesheet
      s._render
      w.style # prime the memo for this frame
      w.styles.normal.fg = 0xaabbcc
      s._render
      w.style.fg.should eq 0xaabbcc
    end
  end

  it "is re-resolved after a stylesheet cascade (css_styled= hook)" do
    s = headless_screen
    w = Widget::Box.new parent: s, width: 10, height: 3
    w.add_css_class "t"
    s._render
    w.style # prime
    s.stylesheet = ".t { color: #ff8800; }"
    s._render
    w.css_styled?.should be_true
    w.style.fg.should eq 0xff8800
  end
end

describe "frame-cached insets" do
  it "ileft/itop follow an inline border+padding swap immediately (floor)" do
    with_saved_theme do
      s = floor_screen
      w = Widget::Box.new parent: s, width: 10, height: 3
      s.apply_stylesheet
      s._render
      w.ileft.should eq 0
      w.style = Style.new(border: true, padding: 1)
      w.ileft.should eq 2
      w.itop.should eq 2
      w.iwidth.should eq 4
      w.iheight.should eq 4
    end
  end

  it "follow a padding change on the backing style by the next frame (floor)" do
    with_saved_theme do
      s = floor_screen
      w = Widget::Box.new parent: s, width: 10, height: 3
      s.apply_stylesheet
      s._render
      w.ileft.should eq 0
      w.styles.normal.padding = Padding.new 3, 0, 0, 0
      s._render
      w.ileft.should eq 3
    end
  end
end

describe "frame-memoized minimal rectangle" do
  it "shrink box resizes when its content changes between frames" do
    s = headless_screen
    w = Widget::Box.new parent: s, top: 0, left: 0, resizable: true,
      content: "ab"
    s._render
    small = (w.lpos.not_nil!.xl - w.lpos.not_nil!.xi)
    w.content = "abcdef"
    s._render
    (w.lpos.not_nil!.xl - w.lpos.not_nil!.xi).should eq small + 4
  end

  it "shrink parent resizes when a child grows between frames" do
    s = headless_screen
    parent = Widget::Box.new parent: s, top: 0, left: 0, resizable: true
    child = Widget::Box.new parent: parent, top: 0, left: 0, width: 4, height: 1
    s._render
    w0 = parent.lpos.not_nil!.xl - parent.lpos.not_nil!.xi
    child.width = 9
    s._render
    (parent.lpos.not_nil!.xl - parent.lpos.not_nil!.xi).should eq w0 + 5
  end
end
