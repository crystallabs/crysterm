require "./spec_helper"

include Crysterm

# CSS length units → terminal cells via the settable `Length.divisors`
# table: `cells = round(value / divisor)`.
describe "CSS geometry units" do
  it "converts a unit'd length to cells through the divisor table" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { width: 200px; left: 12px; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.width_spec.should eq 20 # 200 / 10
    a.left.should eq 1        # round(12 / 10)
  end

  it "passes percentage / keyword forms straight through" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { top: 50%; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.top.as(Crysterm::Dim).matches?("50%").should be_true
  end

  it "ignores a unit mapped to nil (physical units), leaving geometry untouched" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { width: 7; height: 3cm; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.width_spec.should eq 7    # the mapped unit's sibling still applies
    a.height_spec.should be_nil # 3cm dropped -> never set
  end

  it "scales units in non-geometry lengths (padding/margin) too" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { padding: 200px; margin-left: 1em; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.style.padding.left.should eq 20 # 200 / 10            (horizontal)
    a.style.padding.top.should eq 10  # 200 / (10 * 2:1 aspect) (vertical)
    a.style.margin.left.should eq 1   # 1 / 1
  end

  it "caps a stretched/percentage width at max-width" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { width: 100%; max-width: 10; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.max_width.should eq 10
    a.awidth.should eq 10 # 80% of the 80-wide screen, clamped to 10
  end

  it "raises a too-small width to min-width" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { width: 4; min-width: 8; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.awidth.should eq 8
  end

  it "lets min-width win when it exceeds max-width (per CSS)" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { width: 100%; max-width: 5; min-width: 10; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.awidth.should eq 10
  end

  it "scales unit'd size constraints through the divisor table" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { height: 100%; max-height: 200px; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.max_height.should eq 10 # 200 / (10 * 2:1 aspect) -- vertical
    a.aheight.should eq 10    # full 24-row height clamped to 10
  end

  it "resolves a percentage size constraint against the parent, like a percentage size" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { height: 100%; max-height: 200px; min-height: 50%; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    # The spec is stored unresolved and resolved at clamp time, so it tracks the
    # parent rather than being baked to cells once.
    a.min_height.should eq Dim.percent(50)
    a.resolved_min_height.should eq 12 # 50% of the screen's 24 rows
    # `max` applies before `min`, so `min` wins the conflict, per CSS.
    a.aheight.should eq 12

    s.height = 40
    s.repaint
    a.resolved_min_height.should eq 20
    a.aheight.should eq 20
  end

  it "resolves a viewport unit against the screen size, reactively on resize" do
    s = headless_screen(80, 24, default_quit_keys: true) # 80 x 24
    s.stylesheet = "Box#a { width: 50vw; height: 100vh; top: 25vmin; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    # Viewport string is kept on the widget (not baked to cells), re-resolving
    # against the screen every frame.
    a.width_spec.as(Crysterm::Dim).matches?("50vw").should be_true
    a.awidth.should eq 40  # 50% of 80
    a.aheight.should eq 24 # 100% of 24
    a.atop.should eq 6     # 25% of min(80, 24)

    # Resize the terminal: the same widget re-resolves against the new size.
    s.width = 120
    s.height = 40
    s.repaint
    a.awidth.should eq 60  # 50% of 120
    a.aheight.should eq 40 # 100% of 40
    a.atop.should eq 10    # 25% of min(120, 40)
  end

  it "resolves an uppercased viewport unit (units are case-insensitive)" do
    s = headless_screen(80, 24, default_quit_keys: true) # 80 x 24
    # CSS units are case-insensitive: `50VW`/`100VH` must behave like their
    # lowercase forms, and an uppercased size constraint must resolve (not be
    # silently dropped).
    s.stylesheet = "Box#a { width: 50VW; height: 100VH; max-width: 30VW; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.width_spec.as(Crysterm::Dim).matches?("50VW").should be_true # kept as a (reactive) viewport string, not dropped
    a.awidth.should eq 24         # 50% of 80, clamped to max-width (30% of 80 = 24)
    a.aheight.should eq 24        # 100% of 24
    # A viewport constraint is kept unresolved too, so — like a viewport size —
    # it re-resolves against the window on every frame instead of being baked to
    # cells once at cascade time.
    a.max_width.should eq Dim.vw(30)
    a.resolved_max_width.should eq 24 # 30% of 80

    s.width = 120
    s.repaint
    a.resolved_max_width.should eq 36 # 30% of 120
    a.awidth.should eq 36             # 50% of 120 = 60, clamped to 36
  end

  it "evaluates calc() to cells when every term resolves" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { width: calc(200px + 2em); left: calc(8px - 2px); }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.width_spec.should eq 22 # 20 + 2
    a.left.should eq 1        # round(0.8 - 0.2)
  end

  it "accepts a leading-dot decimal length (.5em), bare and inside calc()" do
    # CSS allows a leading-dot decimal (`.5em` == `0.5em`); it must parse the
    # same everywhere — as a bare length, a unit-less number, and a calc() term.
    Crysterm::CSS::Length.to_cells_f(".5em").should eq 0.5           # unit'd, fractional cells
    Crysterm::CSS::Length.to_cells_f("-.5em").should eq -0.5         # signed
    Crysterm::CSS::Length.to_cells_f(".5").should eq 0.5             # bare unit-less number
    Crysterm::CSS::Length.to_cells("calc(.5em + 1.5em)").should eq 2 # leading-dot term in calc()
  end

  it "ignores a calc() that needs layout context (a percentage term)" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { width: 7; height: calc(50% - 10px); }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.width_spec.should eq 7    # sibling still applies
    a.height_spec.should be_nil # calc with `%` -> dropped, never set
  end

  it "resolves a sub-cell border width to no border" do
    # A cell grid can't draw thinner than one cell, and one cell is enormous
    # next to the ~20px-tall widget a desktop QSS theme was written for — so a
    # hairline renders as nothing rather than being clamped up to a full-cell
    # box. Same rule in every spelling (see `Properties.border_cells?`).
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { border-width: 2px; border-left-width: 0; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.style.border.top.should eq 0  # 2px rounds to 0 cells
    a.style.border.left.should eq 0 # explicit 0 stays 0
  end

  it "scales the border-width longhand's top/bottom edges by the cell aspect ratio" do
    # A cell is taller than wide, so an absolute width on top/bottom resolves to
    # fewer cells than on left/right; the shorthand must agree with the longhands.
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { border-width: 200px; } " \
                   "Box#b { border-top-width: 200px; border-left-width: 200px; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    b = Widget::Box.new parent: s, content: "y"
    b.css_id = "b"
    s.repaint
    a.style.border.left.should eq 20 # 200 / 10           (horizontal)
    a.style.border.right.should eq 20
    a.style.border.top.should eq 10 # 200 / (10 * 2.0)   (vertical)
    a.style.border.bottom.should eq 10
    # Per-side longhands resolve the same way, agreeing with the shorthand.
    b.style.border.top.should eq a.style.border.top
    b.style.border.left.should eq a.style.border.left
  end

  it "clamps a negative border width to 0 rather than a negative cell count" do
    # A negative `border-width` must clamp to 0, not a negative count — a
    # negative side would shrink the widget via `SidedGeometry#adjust`.
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { border-width: -20px; } " \
                   "Box#b { border-top-width: -3; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    b = Widget::Box.new parent: s, content: "y"
    b.css_id = "b"
    s.repaint
    a.style.border.top.should eq 0 # -20px -> -2 cells, clamped to 0
    a.style.border.left.should eq 0
    b.style.border.top.should eq 0 # bare -3 -> clamped to 0
  end

  it "honors a sub-cell width as no border in the border shorthand" do
    # Qt stylesheets put hairline widths in the `border`/`border-<side>`
    # shorthand. In a cell grid these round to 0, and every spelling —
    # shorthand and `border-width` longhand alike — agrees on that.
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { border: 0.04em solid #cccccc; } " \
                   "Box#b { border: 1px solid #cccccc; } " \
                   "Box#c { border: solid #cccccc; } " \
                   "Box#d { border: 2 solid #cccccc; } " \
                   "Box#e { border-top: 0.04em solid #cccccc; }"
    %w[a b c d e].each do |id|
      w = Widget::Box.new parent: s, content: "x"
      w.css_id = id
    end
    s.repaint
    boxes = s.children.to_a.compact_map(&.as?(Widget::Box))
    by = ->(id : String) { boxes.find! { |w| w.css_id == id }.style.border }
    by.call("a").any?.should be_false # 0.04em -> 0 cells -> no border
    by.call("b").any?.should be_false # 1px    -> 0 cells -> no border
    by.call("c").top.should eq 1      # no width given -> default 1-cell border
    by.call("d").top.should eq 2      # bare cell count honored
    by.call("e").top.should eq 0      # hairline side stays invisible despite `solid`
  end

  it "clamps an absurd length instead of overflowing (never raises)" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { width: 99999999999px; height: calc(99999999999px * 99); }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint # must not raise OverflowError
    a.width_spec.should eq Int32::MAX
    a.height_spec.should eq Int32::MAX
  end

  it "seeds the px divisor from the css.px_per_cell config option" do
    Superconf.css_px_per_cell = 5.0
    begin
      s = headless_screen(80, 24, default_quit_keys: true)
      s.stylesheet = "Box#a { width: 200px; }"
      a = Widget::Box.new parent: s, content: "x"
      a.css_id = "a"
      s.repaint
      a.width_spec.should eq 40 # 200 / 5
    ensure
      Superconf.css_px_per_cell = 10.0 # back to default ⇒ un-configured
      Crysterm::CSS::Length.divisors["px"] = 10.0
    end
  end

  it "seeds divisors from a css.unit_divisors map, with px_per_cell winning for px" do
    Superconf.css_unit_divisors = "px=4,em=2,cm=none,junk"
    Superconf.css_px_per_cell = 8.0
    begin
      s = headless_screen(80, 24, default_quit_keys: true)
      s.stylesheet = "Box#a { width: 200px; height: 4em; }"
      a = Widget::Box.new parent: s, content: "x"
      a.css_id = "a"
      s.repaint
      a.width_spec.should eq 25 # map px=4, then px_per_cell=8 wins ⇒ 200 / 8
      a.height_spec.should eq 2 # em=2 from the map ⇒ 4 / 2
    ensure
      Superconf.css_unit_divisors = ""
      Superconf.css_px_per_cell = 10.0
      Crysterm::CSS::Length.divisors["px"] = 10.0
      Crysterm::CSS::Length.divisors["em"] = 1.0
    end
  end

  it "maps the same absolute length to fewer cells vertically (cell aspect ratio)" do
    s = headless_screen(80, 24, default_quit_keys: true)
    # Same px length on both axes; vertical resolves to fewer cells (default 2:1
    # aspect ratio).
    s.stylesheet = "Box#a { width: 200px; height: 200px; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.width_spec.should eq 20  # 200 / 10
    a.height_spec.should eq 10 # 200 / (10 * 2.0)
  end

  it "leaves relative units (em/ch) isotropic regardless of axis" do
    s = headless_screen(80, 24, default_quit_keys: true)
    s.stylesheet = "Box#a { width: 4em; height: 4em; }"
    a = Widget::Box.new parent: s, content: "x"
    a.css_id = "a"
    s.repaint
    a.width_spec.should eq 4  # 4 / 1
    a.height_spec.should eq 4 # 4 / 1 -- not scaled by the aspect ratio
  end

  it "honors an explicit css.cell_aspect_ratio override" do
    Superconf.css_cell_aspect_ratio = 4.0
    begin
      s = headless_screen(80, 24, default_quit_keys: true)
      s.stylesheet = "Box#a { width: 200px; height: 200px; }"
      a = Widget::Box.new parent: s, content: "x"
      a.css_id = "a"
      s.repaint
      a.width_spec.should eq 20 # 200 / 10 (horizontal, unaffected)
      a.height_spec.should eq 5 # 200 / (10 * 4.0)
    ensure
      Superconf.css_cell_aspect_ratio = 2.0
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
    end
  end

  it "honors a retuned divisor" do
    original = Crysterm::CSS::Length.divisors["px"]
    begin
      Crysterm::CSS::Length.divisors["px"] = 20.0
      s = headless_screen(80, 24, default_quit_keys: true)
      s.stylesheet = "Box#a { width: 200px; }"
      a = Widget::Box.new parent: s, content: "x"
      a.css_id = "a"
      s.repaint
      a.width_spec.should eq 10 # 200 / 20
    ensure
      Crysterm::CSS::Length.divisors["px"] = original
    end
  end
end
