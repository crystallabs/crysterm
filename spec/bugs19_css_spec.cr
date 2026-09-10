require "./spec_helper"

include Crysterm

# Regression specs for the Style/CSS engine hardening pass: cyclic `@import`
# protection, saturation of pathological length/radius values through the
# cascade and layout, `merge_stylesheet` source-order tie-breaking, and the
# per-tier sheet bias staying overflow-free with many per-widget sheets.

describe "Crysterm::CSS::Stylesheet @import cycle protection" do
  it "parses a self-importing @import without stack overflow and records a warning" do
    dir = File.tempname("crysterm-cyclic-import")
    Dir.mkdir dir
    path = File.join(dir, "self.css")
    File.write path, %(@import "self.css";\nBox { color: red; })
    begin
      sheet = Crysterm::CSS::Stylesheet.parse(File.read(path), base_path: path)
      sheet.warnings.any?(&.includes?("cyclic import")).should be_true
      # The importing file's own rules, declared after the cyclic @import,
      # still parse (only the re-entrant import call is skipped).
      sheet.rules.any?(&.selector.includes?("Box")).should be_true
    ensure
      File.delete? path
      Dir.delete(dir) rescue nil
    end
  end

  it "parses a mutual @import cycle (A -> B -> A) without stack overflow" do
    dir = File.tempname("crysterm-cyclic-import-mutual")
    Dir.mkdir dir
    a = File.join(dir, "a.css")
    b = File.join(dir, "b.css")
    File.write a, %(@import "b.css";\nA { color: red; })
    File.write b, %(@import "a.css";\nB { color: blue; })
    begin
      sheet = Crysterm::CSS::Stylesheet.parse(File.read(a), base_path: a)
      sheet.warnings.any?(&.includes?("cyclic import")).should be_true
      selectors = sheet.rules.map(&.selector)
      selectors.any?(&.includes?("A")).should be_true
      selectors.any?(&.includes?("B")).should be_true
    ensure
      File.delete? a
      File.delete? b
      Dir.delete(dir) rescue nil
    end
  end
end

describe "huge CSS lengths saturate instead of raising" do
  it "accepts a huge border-radius without raising, clamped to Int32::MAX" do
    screen = headless_screen(default_quit_keys: true)
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 40, height: 10

    screen.stylesheet = "Box { border-radius: 99999999999; }"
    screen.apply_stylesheet
    screen.repaint

    corners = box.styles.normal.border.corners
    corners.tl.should eq Border::Corner::Rounded
    corners.radii[0].should eq Int32::MAX
  end

  it "accepts huge padding/margin without raising, clamped to a sane cell range" do
    screen = headless_screen(default_quit_keys: true)
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 40, height: 10

    screen.stylesheet = "Box { padding-left: 99999999999; margin-left: -99999999999; }"
    screen.apply_stylesheet
    screen.repaint

    box.styles.normal.padding.left.should eq 1_000_000
    box.styles.normal.margin.left.should eq -1_000_000
  end

  it "accepts a huge tab-size without raising or attempting a huge allocation" do
    screen = headless_screen(default_quit_keys: true)
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 40, height: 10

    screen.stylesheet = "Box { tab-size: 99999999999; }"
    screen.apply_stylesheet
    screen.repaint

    box.styles.normal.tab_size.should eq 1_000_000

    # Expanding a tab multiplies the fill char by `tab_size` — clamped cell
    # count keeps this a ~1MB allocation instead of the ~2GB a raw
    # `Int32::MAX` would attempt. `process_content` is where the expansion
    # (`clean_content_chars`) actually runs; the raw `#content` getter would
    # just echo the unexpanded string back.
    box.content = "a\tb"
    box.process_content
    box.rendered_text.size.should be < 2_000_000
  end

  it "accepts a huge border-width without raising" do
    screen = headless_screen(default_quit_keys: true)
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 40, height: 10

    screen.stylesheet = "Box { border: solid; border-width: 99999999999; }"
    screen.apply_stylesheet
    screen.repaint

    box.styles.normal.border.left.should eq 1_000_000
  end
end

# `merge_stylesheet` (`src/dom/inline_css.cr`) is compiled unconditionally
# (required ahead of the `-Dremote`-gated network surface in `crysterm.cr`),
# but this exact code path — layering an object-assigned author sheet under a
# recomposed text source — is exercised elsewhere in the suite only under
# `-Dremote` (see `spec/dom_inline_css_spec.cr`), so this stays guarded the
# same way for consistency.
{% if flag?(:remote) %}
  describe "Window#merge_stylesheet source-order tie-breaking" do
    it "lets the later (text) sheet win over an object-assigned base sheet on an equal-specificity tie" do
      screen = headless_screen(default_quit_keys: true)
      box = Widget::Box.new
      box.css_id = "x"
      screen.append box

      # `base` carries an unrelated rule before its #x rule, so the #x rule's
      # source order collides with `extra`'s (both parsed independently,
      # each starting its own order count from 0) unless `merge_stylesheet`
      # renumbers `extra`'s rules past `base`'s.
      base = Crysterm::CSS::Stylesheet.parse("A { color: white; }\n#x { color: red; }")
      screen.stylesheet = base                                                 # object source, applied directly (no merge yet)
      screen.add_inline_stylesheet("B { color: white; }\n#x { color: blue; }") # triggers merge_stylesheet(base, parsed)
      screen.apply_stylesheet

      box.styles.normal.fg.should eq rgb("blue") # the later (inline) sheet wins the tie
    end
  end
{% end %}

describe "per-tier sheet bias with many per-widget stylesheets" do
  it "does not overflow applying more than 215 widgets each with their own stylesheet" do
    screen = headless_screen(default_quit_keys: true)
    # Each widget's own `stylesheet=` contributes one sheet at TIER_WIDGET;
    # 300 of them pushes the per-tier sheet slot well past the 215 that
    # overflowed the old Int32 multiplicative bias.
    widgets = Array.new(300) { Widget::Box.new parent: screen }
    widgets.each(&.stylesheet=("Box { color: red; }"))

    screen.apply_stylesheet

    widgets.each(&.styles.normal.fg.should(eq(rgb("red"))))
  end
end
