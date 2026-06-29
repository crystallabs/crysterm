require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# See `css_cascade_spec.cr`: empty the auto-installed default theme so its
# `Widget { color: var(--text) }` base rule (folded into *every* materialized
# state) doesn't itself supply the color and mask the inheritance gap under test.
private def without_default_theme(&)
  saved = Crysterm::CSS.default_stylesheet
  Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
  begin
    yield
  ensure
    Crysterm::CSS.default_stylesheet = saved
  end
end

private def rgb(name)
  Crysterm::Colors.convert(name).to_i32
end

# An inherited value (`color`/`font-weight`/`font-style`) is stateless, so it
# must reach every state a widget actually renders in — not only `normal`. A
# materialized non-normal state (one given its own `:focus`/`:selected` rule)
# that leaves an inherited property unset previously reverted to the terminal
# default for that property the moment the widget entered the state.
describe "CSS inheritance into materialized states" do
  it "inherits color/weight/slant into a state materialized by a non-color rule" do
    screen = headless_screen
    form = Widget::Form.new
    inner = Widget::Box.new # styled only via inheritance + a bg-only :focus rule
    form.append inner
    screen.append form

    without_default_theme do
      screen.stylesheet = <<-CSS
        Form { color: yellow; font-weight: bold; font-style: italic; }
        Box:focus { background-color: blue; }
      CSS
      screen.apply_stylesheet

      # The :focus rule materialized a distinct focused style (only setting bg).
      inner.styles.focused.should_not be inner.styles.normal
      inner.styles.focused.bg.should eq rgb("blue")

      # The inherited color/weight/slant must show in the focused state too —
      # otherwise a focused field renders with the default fg (the bug).
      inner.styles.focused.fg.should eq rgb("yellow")
      inner.styles.focused.bold?.should be_true
      inner.styles.focused.italic?.should be_true

      # normal state still inherits, as before.
      inner.styles.normal.fg.should eq rgb("yellow")
    end
  end

  it "does not override a property the materialized state sets for itself" do
    screen = headless_screen
    form = Widget::Form.new
    inner = Widget::Box.new
    inner.css_id = "inner"
    form.append inner
    screen.append form

    without_default_theme do
      screen.stylesheet = <<-CSS
        Form { color: yellow; }
        #inner:focus { color: red; }
      CSS
      screen.apply_stylesheet

      # The focused state sets its own color, which wins over the inherited one.
      inner.styles.focused.fg.should eq rgb("red")
      # normal still inherits the ancestor color.
      inner.styles.normal.fg.should eq rgb("yellow")
    end
  end

  it "leaves a lazily-falling-back state untouched (still resolves to normal)" do
    screen = headless_screen
    form = Widget::Form.new
    inner = Widget::Box.new
    form.append inner
    screen.append form

    without_default_theme do
      # No rule materializes any non-normal state for `inner`.
      screen.stylesheet = "Form { color: yellow; }"
      screen.apply_stylesheet

      # `focused` lazily falls back to the same `normal` object (not a distinct
      # inherited-into copy), which already carries the inherited color.
      inner.styles.focused.should be inner.styles.normal
      inner.styles.focused.fg.should eq rgb("yellow")
    end
  end
end
