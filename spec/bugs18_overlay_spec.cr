require "./spec_helper"

include Crysterm

# Regression spec for BUGS18 B18-80:
#
# The `Media::ScreenOverlay` erase lifecycle had exactly one trigger for the
# hidden case — the `on(Event::Hide) { clear_overlay }` hook, which fires only
# from `Widget#hide`. The CSS engine hides widgets by writing the computed
# style flag directly (`visibility: hidden` / `display: none` →
# `style.visible = false`), never emitting `Event::Hide`; and both render-time
# listeners gated themselves OUT of the clear path while hidden
# (`return unless overlay_visible? && visible?`). So a CSS-driven hide left a
# Kitty image (a separate pixel layer re-emitted cells cannot cover) floating
# over whatever the layout drew in its place, indefinitely. The hidden-ANCESTOR
# variant leaked the same way (self `visible?` true, but `redraw_image` bails
# on `visible_in_tree?` and nothing erases).
#
# Fix: the "no longer drawable" decision in `invalidate_old_position` /
# `overlay_rendered` is made by the shared `#overlay_drawable_rect`
# (`visible_in_tree?` + resolvable, non-degenerate rect) instead of skipping
# the clear while hidden. Sibling `Media::Ueberzug#redraw_image` (its own
# `Rendered` hook, erased only via `on(Event::Hide) { remove }`) now calls
# `remove` when the geometry is not drawable, taking the always-on-top helper
# window down on a CSS-driven hide.

private def overlay_screen(w = 20, h = 10)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: w, height: h, default_quit_keys: false)
end

private def red_bitmap(w = 8, h = 8)
  red = PNGGIF::Pixel.new(255, 0, 0, 255)
  Array(Array(PNGGIF::Pixel)).new(h) { Array(PNGGIF::Pixel).new(w, red) }
end

private HIDE_CSS = <<-CSS
  .hidden { visibility: hidden; }
  CSS

# Sixel spy exposing the shared `Media::ScreenOverlay` private state and
# counting the erase (`overlay_cleared`) hook invocations (same shape as the
# bugs12 overlay-lifecycle spec).
private class SpySixel < Crysterm::Widget::Media::Sixel
  getter cleared_count = 0

  def spy_last_drawn
    @last_drawn
  end

  protected def overlay_cleared(s : ::Crysterm::Window)
    @cleared_count += 1
    super
  end
end

# Records the JSON protocol a Ueberzug widget would emit, without a helper
# process; exposes `@last`/`@path` for assertions.
private class SpyUeberzug < Crysterm::Widget::Media::Ueberzug
  getter commands = [] of String

  def peek_last
    @last
  end

  def force_path(p : String)
    @path = p
  end

  private def send(command, retry_once = true)
    @commands << command.to_json
  end
end

describe "BUGS18 B18-80 CSS-driven hide erases the window overlay" do
  it "clears the graphic when the widget itself is hidden via CSS visibility, and repaints on re-show" do
    s = overlay_screen
    s.stylesheet = HIDE_CSS
    img = SpySixel.new parent: s, top: 0, left: 0, width: 6, height: 4
    img.bitmap = red_bitmap

    s.repaint
    img.spy_last_drawn.should_not be_nil
    img.cleared_count.should eq 0

    # CSS class toggle: the cascade writes style.visible = false directly, no
    # Event::Hide is ever emitted — the render-time listeners must run the
    # clear path themselves.
    img.add_css_class "hidden"
    s.repaint
    img.visible?.should be_false
    img.cleared_count.should eq 1
    img.spy_last_drawn.should be_nil

    # Still hidden: the clear must not re-run every frame.
    s.repaint
    img.cleared_count.should eq 1

    # CSS re-show: the graphic repaints (fresh painted rect).
    img.remove_css_class "hidden"
    s.repaint
    img.visible?.should be_true
    img.spy_last_drawn.should_not be_nil
    img.cleared_count.should eq 1
  end

  it "clears the graphic when an ANCESTOR is hidden via CSS (self visible? stays true)" do
    s = overlay_screen
    s.stylesheet = HIDE_CSS
    pane = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 8
    img = SpySixel.new parent: pane, top: 0, left: 0, width: 6, height: 4
    img.bitmap = red_bitmap

    s.repaint
    img.spy_last_drawn.should_not be_nil

    pane.add_css_class "hidden"
    s.repaint
    # Only the ancestor is hidden — no Hide propagates, self flag unchanged.
    img.visible?.should be_true
    img.visible_in_tree?.should be_false
    img.cleared_count.should eq 1
    img.spy_last_drawn.should be_nil

    pane.remove_css_class "hidden"
    s.repaint
    img.spy_last_drawn.should_not be_nil
  end

  it "keeps the Event::Hide fast path working (widget.hide clears immediately)" do
    s = overlay_screen
    img = SpySixel.new parent: s, top: 0, left: 0, width: 6, height: 4
    img.bitmap = red_bitmap

    s.repaint
    img.spy_last_drawn.should_not be_nil

    img.hide
    img.cleared_count.should eq 1
    img.spy_last_drawn.should be_nil

    # The relaxed render-time listeners must not double-clear afterwards.
    s.repaint
    img.cleared_count.should eq 1
  end
end

describe "BUGS18 B18-80 sibling: Ueberzug removes its placement on a CSS-driven hide" do
  it "sends remove when the widget becomes CSS-hidden, and re-adds on re-show" do
    s = overlay_screen
    s.stylesheet = HIDE_CSS
    img = SpyUeberzug.new parent: s, top: 0, left: 0, width: 6, height: 4
    img.force_path "/nonexistent/spec.png"

    s.repaint
    img.peek_last.should_not be_nil
    img.commands.last.should contain %("action":"add")

    # CSS hide: no Event::Hide fires, so the `on(Hide) { remove }` hook is
    # bypassed — redraw_image must take the always-on-top placement down when
    # the geometry is no longer drawable.
    img.add_css_class "hidden"
    s.repaint
    img.peek_last.should be_nil
    img.commands.last.should contain %("action":"remove")

    # Still hidden: `remove` is @last-guarded, no command churn.
    n = img.commands.size
    s.repaint
    img.commands.size.should eq n

    # Re-show re-places the image.
    img.remove_css_class "hidden"
    s.repaint
    img.peek_last.should_not be_nil
    img.commands.last.should contain %("action":"add")
  end
end
