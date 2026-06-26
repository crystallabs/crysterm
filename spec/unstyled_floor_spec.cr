require "./spec_helper"

# The "unstyled floor": with `colors.theme = none` and no author stylesheet, the
# CSS cascade does nothing (see `Screen#apply_stylesheet`) and widgets keep their
# programmatic, color-agnostic look. This suite renders representative widgets in
# that state and asserts they stay *usable* with zero color assumptions:
#
#   * a selected row/item is distinguishable via reverse-video (the one highlight
#     that needs no color and reads on any terminal background);
#   * overlays (Menu, ...) separate from content via a default structural border
#     that a theme is still free to override (including to none).
#
# Gated to `-Dremote` like the other render specs (so the bridge/headless paths
# are active).
{% if flag?(:remote) %}
  include Crysterm

  # A headless screen with the unstyled floor forced: no theme is installed and
  # the default (user-agent) stylesheet is empty, so `apply_stylesheet` is a
  # no-op and widgets render programmatically. `ensure_theme` runs once on
  # construction, so the theme is cleared *after* the screen exists.
  private def floor_screen(width = 40, height = 12)
    s = Crysterm::Screen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: width, height: height)
    Crysterm::CSS.theme = nil
    s
  end

  # Whether any cell in row *y* (columns *x0*..*x1*) carries reverse-video.
  private def row_has_reverse?(s, y, x0 = 0, x1 = nil)
    x1 ||= s.awidth - 1
    (x0..x1).any? do |x|
      (Crysterm::Attr.flags(s.lines[y][x].attr) & Crysterm::Attr::REVERSE) != 0
    end
  end

  describe "unstyled floor (colors.theme = none)" do
    # The active theme / default stylesheet is process-global. Restore whatever
    # was installed before each example after it runs, so forcing the floor here
    # can't leak "no theme" into specs that run later in the same process.
    around_each do |example|
      saved_theme = Crysterm::CSS.theme
      saved_default = Crysterm::CSS.default_stylesheet
      example.run
      Crysterm::CSS.theme = saved_theme
      Crysterm::CSS.default_stylesheet = saved_default
    end

    it "renders without any theme rules active" do
      s = floor_screen
      Crysterm::Widget::List.new parent: s, top: 0, left: 0, width: 20, height: 5, items: %w[a b]
      s.apply_stylesheet
      Crysterm::CSS.default_stylesheet.rules.empty?.should be_true
    end

    it "shows a List's selected row via reverse-video" do
      s = floor_screen
      list = Crysterm::Widget::List.new parent: s, top: 0, left: 0, width: 20, height: 6,
        items: %w[Alpha Beta Gamma Delta]
      list.focus
      list.selekt 2
      s.apply_stylesheet
      s._render

      list.css_styled?.should be_false # confirm we are on the non-CSS floor path
      # The selected row (index 2) is at content row 2 of a borderless list.
      row_has_reverse?(s, 2, 0, list.awidth.not_nil! - 1).should be_true
      # Non-selected rows stay plain.
      row_has_reverse?(s, 0, 0, list.awidth.not_nil! - 1).should be_false
    end

    it "shows a ListBar's selected item via reverse-video" do
      s = floor_screen
      lb = Crysterm::Widget::ListBar.new parent: s, top: 0, left: 0, width: 40, height: 1,
        keys: true, mouse: true
      lb.set_items(%w[File Edit View])
      lb.focus
      s.apply_stylesheet
      s._render

      lb.css_styled?.should be_false
      # `set_items` selects index 0; its box renders reverse at the floor.
      row_has_reverse?(s, 0).should be_true
    end

    it "gives an overlay (Menu) a structural border at the floor" do
      s = floor_screen
      m = Crysterm::Widget::Menu.new parent: s, top: 0, left: 0, width: 12, height: 5
      m.add "New"
      m.add "Quit"
      s.apply_stylesheet
      s._render

      m.css_styled?.should be_false
      m.style.border.any?.should be_true
      # The floor border is *not* seeded into the cascade base, so a theme stays
      # in full control (free to set border: 0) — no themed regression.
      m.css_base_styles.normal.border.any?.should be_false
    end

    it "does not give a plain content widget (List) a border at the floor" do
      s = floor_screen
      list = Crysterm::Widget::List.new parent: s, top: 0, left: 0, width: 12, height: 5,
        items: %w[a b]
      s.apply_stylesheet
      s._render
      list.style.border.any?.should be_false
    end
  end
{% end %}
