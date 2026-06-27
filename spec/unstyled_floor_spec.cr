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

    it "shows a focused Button via reverse-video at the floor" do
      s = floor_screen
      btn = Crysterm::Widget::Button.new parent: s, top: 0, left: 0, width: 12, height: 1,
        content: "OK"
      btn.state = :focused
      s.apply_stylesheet
      s._render

      btn.css_styled?.should be_false # confirm we are on the non-CSS floor path
      btn.floor_focus_reverse?.should be_true
      btn.style.reverse?.should be_true
      row_has_reverse?(s, 0, btn.aleft.not_nil!, btn.aleft.not_nil! + btn.awidth.not_nil! - 1).should be_true

      # A non-focused button stays plain (no stray inversion).
      btn.state = :normal
      btn.style.reverse?.should be_false
    end

    it "applies a fade's alpha to a focused Button at the floor" do
      # At the floor `#style` returns a transient reverse-video `#dup` for a
      # focused small control, so a fade that wrote `style.alpha` through `#style`
      # would land on a throwaway and never take effect. `#set_alpha` must write
      # the persistent `#state_style` (like `#set_visible`), so the value survives
      # to the render-time `#dup`.
      s = floor_screen
      btn = Crysterm::Widget::Button.new parent: s, top: 0, left: 0, width: 12, height: 1,
        content: "OK"
      btn.state = :focused
      btn.css_styled?.should be_false # confirm the non-CSS floor path
      btn.floor_focus_reverse?.should be_true

      anim = btn.fade_in # synchronously sets alpha to 0.0, then tweens up
      anim.stop
      btn.style.alpha?.should eq 0.0
    end

    it "shows other focusable controls (Slider/SpinBox/Dial) via reverse-video at the floor" do
      s = floor_screen
      controls = [
        Crysterm::Widget::Slider.new(parent: s, top: 0, left: 0, width: 12, height: 1,
          minimum: 0, maximum: 10, value: 5),
        Crysterm::Widget::SpinBox.new(parent: s, top: 0, left: 0, width: 6, height: 1,
          minimum: 0, maximum: 10, value: 5),
        Crysterm::Widget::Dial.new(parent: s, top: 0, left: 0, width: 7, height: 5,
          minimum: 0, maximum: 10, value: 5),
      ] of Crysterm::Widget

      controls.each do |c|
        c.floor_focus_reverse?.should be_true
        c.state = :normal
        c.style.reverse?.should be_false # unfocused stays plain
        c.state = :focused
        c.css_styled?.should be_false
        c.style.reverse?.should be_true
      end
    end

    it "does not reverse-video a focused plain container (Box) at the floor" do
      s = floor_screen
      box = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 12, height: 3,
        content: "hi"
      box.state = :focused
      s.apply_stylesheet

      box.css_styled?.should be_false
      box.floor_focus_reverse?.should be_false # large widgets opt out
      box.style.reverse?.should be_false
    end

    it "frames a floating DockWidget and borders a docked one on the content-facing edge" do
      s = floor_screen
      floating = Crysterm::Widget::DockWidget.new parent: s, title: "F",
        area: Crysterm::Widget::DockWidget::Area::Floating, top: 0, left: 0, width: 14, height: 5
      left_docked = Crysterm::Widget::DockWidget.new parent: s, title: "D",
        area: Crysterm::Widget::DockWidget::Area::Left, top: 0, left: 0, width: 14, height: 5
      s.apply_stylesheet
      s._render

      floating.css_styled?.should be_false # on the non-CSS floor
      # Floating overlay → full frame.
      fb = floating.style.border
      {fb.left?, fb.top?, fb.right?, fb.bottom?}.should eq({true, true, true, true})
      # Docked Left → only the right edge (the one facing the central content).
      lb = left_docked.style.border
      {lb.left?, lb.top?, lb.right?, lb.bottom?}.should eq({false, false, true, false})

      # Rendered: that single right divider spans the *full* height — including
      # the titlebar row and the bottom row, not just the interior — so a partial
      # border isn't clipped at its corners.
      col = left_docked.aleft.not_nil! + left_docked.awidth.not_nil! - 1
      bottom = left_docked.atop.not_nil! + left_docked.aheight.not_nil! - 1
      s.lines[left_docked.atop.not_nil!][col].char.should eq '│'
      s.lines[bottom][col].char.should eq '│'

      # The border *syncs* as the dock floats/re-docks: a re-dock must drop back to
      # the single content-facing edge, not keep the full floating frame.
      left_docked.toggle_floating                   # → floating
      left_docked.style.border.left?.should be_true # now a full frame
      left_docked.toggle_floating                   # → docked Left again
      b = left_docked.style.border
      {b.left?, b.top?, b.right?, b.bottom?}.should eq({false, false, true, false})

      # The floor border never seeds the cascade base, so a theme stays in control.
      floating.css_base_styles.normal.border.any?.should be_false
    end

    it "fills Splitter dividers with a line glyph at the floor" do
      s = floor_screen
      sp = Crysterm::Widget::Splitter.new parent: s, orientation: Tput::Orientation::Horizontal,
        top: 0, left: 0, width: 22, height: 4
      sp.add_pane Crysterm::Widget::Box.new(content: "A")
      sp.add_pane Crysterm::Widget::Box.new(content: "B")
      s.apply_stylesheet
      s._render

      div = sp.dividers.first
      div.css_styled?.should be_false   # no `.divider` rule on the floor
      div.style.fill_char.should eq '│' # vertical divider between side-by-side panes
      # And it actually paints: the divider column shows the glyph.
      s.lines[div.atop.not_nil!][div.aleft.not_nil!].char.should eq '│'
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
