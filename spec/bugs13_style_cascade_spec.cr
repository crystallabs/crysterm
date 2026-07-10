require "./spec_helper"

include Crysterm

# Regression specs for the BUGS13 cascade/reset/memo batch:
#
# * S1 — `Style#fold_specified_onto` must copy the mutable box sub-objects
#   (border/padding/margin/shadow); shared references let the cascade's
#   longhand tiers corrupt the user's inline `@style` in place.
# * S3 — a cascade reset (`styles=`) drops the floor-border sync memo, so an
#   overlay that rendered unstyled reinstalls its floor border after a reset.
# * S4 — a programmatic `hide` on a rule-unmatched widget under active CSS
#   survives the next recascade (persisted onto the pristine snapshot).
# * S6 — a cascade reset invalidates the pushed sub-style memo
#   (`Widget#_substyle_src`), so ancestors re-push `::pane`/`::tab`/`::title`.
# * S9 — a widget reparented from a styled window to a rule-less window is
#   reverted to pristine (the arrival arms the target's reset pass).

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# Runs *block* with the global default (user-agent) stylesheet emptied, then
# restores it, so computed-style asserts aren't foiled by a theme.
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

# A plain box that carries a floor border (like Menu/Dialog/ToolTip overlays).
private class FloorBox < Crysterm::Widget::Box
  def floor_border? : Bool
    true
  end
end

describe "BUGS13 S1 fold_specified_onto copies mutable box props" do
  it "border edits on the folded copy don't corrupt the source" do
    src = Style.new
    src.border = true
    dst = Style.new
    src.fold_specified_onto dst
    dst.border.left = 0
    src.border.left.should eq 1
  end

  it "padding/margin/shadow edits on the copy don't corrupt the source" do
    src = Style.new
    Crysterm::CSS::Properties.apply(src, "padding", "2")
    Crysterm::CSS::Properties.apply(src, "margin", "3")
    Crysterm::CSS::Properties.apply(src, "box-shadow", "0.5")
    dst = Style.new
    src.fold_specified_onto dst
    dst.padding.left = 9
    dst.margin.top = 9
    dst.shadow.horizontal_char = 'x'
    src.padding.left.should eq 2
    src.margin.top.should eq 3
    src.shadow.horizontal_char.should be_nil
  end

  it "an !important border longhand does not corrupt the widget's inline @style" do
    without_default_theme do
      screen = headless_screen
      inline = Style.new
      inline.border = true
      box = Widget::Box.new parent: screen, width: 10, height: 5, style: inline
      screen.stylesheet = "Box { border-left-width: 0 !important; }"
      screen._render
      # The computed style honors the rule ...
      box.style.border.left.should eq 0
      # ... but the user's inline object is untouched (was mutated to 0).
      inline.border.left.should eq 1
    end
  end

  it "state materialization doesn't leak border edits across states" do
    without_default_theme do
      screen = headless_screen
      inline = Style.new
      inline.border = true
      box = Widget::Box.new parent: screen, width: 10, height: 5, style: inline
      screen.stylesheet = "Box:focus { border-left-width: 0 !important; }"
      screen._render
      # The focused state got its own border object; normal keeps the inline's.
      box.styles.focused.border.left.should eq 0
      box.styles.normal.border.left.should eq 1
      inline.border.left.should eq 1
    end
  end
end

describe "BUGS13 S3 cascade reset reinstalls the floor border" do
  it "keeps the floor border after a cascade that doesn't match the widget" do
    without_default_theme do
      screen = headless_screen
      box = FloorBox.new parent: screen, width: 10, height: 5
      screen._render
      box.style.border.left.should eq 1 # floor border installed at the unstyled floor

      screen.stylesheet = "Label { color: red; }" # active CSS; box matches nothing
      screen._render
      box.css_styled?.should be_false
      box.style.border.left.should eq 1 # was 0: memo skipped the reinstall forever
    end
  end

  it "keeps the floor border after CSS is cleared again" do
    without_default_theme do
      screen = headless_screen
      box = FloorBox.new parent: screen, width: 10, height: 5
      screen._render
      screen.stylesheet = "Box { color: red; }" # matches: cascade owns the border
      screen._render
      box.css_styled?.should be_true

      screen.stylesheet = nil # back to the unstyled floor (reset pass)
      screen._render
      box.css_styled?.should be_false
      box.style.border.left.should eq 1
    end
  end
end

describe "BUGS13 S4 programmatic hide survives a recascade for unmatched widgets" do
  it "keeps a hidden rule-unmatched widget hidden across a restyle" do
    without_default_theme do
      screen = headless_screen
      box = Widget::Box.new parent: screen, width: 10, height: 5
      screen.stylesheet = "Label { color: red; }" # active CSS; box matches nothing
      screen._render
      box.css_styled?.should be_false

      box.hide
      box.visible?.should be_false
      box.add_css_class "poke" # attribute change -> the document changes -> recascade
      screen._render
      box.visible?.should be_false # was true: the reset wiped the computed-only write
    end
  end

  it "show() is persisted symmetrically" do
    without_default_theme do
      screen = headless_screen
      box = Widget::Box.new parent: screen, width: 10, height: 5
      screen.stylesheet = "Label { color: red; }"
      screen._render
      box.hide
      screen._render
      box.show
      box.visible?.should be_true
      box.remove_css_class "poke" # no-op class change; add one to force a change
      box.add_css_class "poke2"
      screen._render
      box.visible?.should be_true
    end
  end

  it "hide on a never-cascaded widget still works (no snapshot side effects)" do
    without_default_theme do
      screen = headless_screen
      box = Widget::Box.new parent: screen, width: 10, height: 5
      box.hide
      box.visible?.should be_false
      box.show
      box.visible?.should be_true
    end
  end
end

describe "BUGS13 S6 cascade reset invalidates the pushed-substyle memo" do
  it "nils Widget#_substyle_src when the cascade resets the widget" do
    without_default_theme do
      screen = headless_screen
      box = Widget::Box.new parent: screen, width: 5, height: 3
      box._substyle_src = Style.new
      screen.stylesheet = "Box { color: red; }"
      screen._render
      box._substyle_src.should be_nil
    end
  end

  it "nils the memo on the revert-to-pristine (stylesheet cleared) pass too" do
    without_default_theme do
      screen = headless_screen
      box = Widget::Box.new parent: screen, width: 5, height: 3
      screen.stylesheet = "Box { color: red; }"
      screen._render
      box._substyle_src = Style.new
      screen.stylesheet = nil
      screen._render
      box._substyle_src.should be_nil
    end
  end
end

describe "BUGS13 S9 reparenting a styled widget to a rule-less window reverts it" do
  it "drops the old window's computed styles and css_styled flag" do
    without_default_theme do
      a = headless_screen
      b = headless_screen
      a.stylesheet = "Box { color: red; }"
      box = Widget::Box.new parent: a, width: 5, height: 3
      a._render
      box.css_styled?.should be_true
      box.style.fg.should eq rgb("red")

      b.insert box # cross-window move; b has no active rules
      b._render
      box.css_styled?.should be_false # was stuck true
      box.style.fg.should be_nil      # was red forever
    end
  end

  it "re-enables the inline @style short-circuit on the rule-less window" do
    without_default_theme do
      a = headless_screen
      b = headless_screen
      a.stylesheet = "Box { color: red; }"
      inline = Style.new
      inline.fg = "cyan"
      box = Widget::Box.new parent: a, width: 5, height: 3, style: inline
      a._render
      box.css_styled?.should be_true

      b.insert box
      b._render
      box.css_styled?.should be_false
      box.style.fg.should eq rgb("cyan") # inline wins wholesale again
    end
  end
end
