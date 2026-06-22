require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def rgb(name)
  Crysterm::Colors.convert(name).to_i32
end

# End-to-end behavior lock for the CSS cascade: parsing a stylesheet, matching it
# against the widget tree, and folding declarations into each widget's per-state
# `Style`/`Styles`.
describe "CSS cascade" do
  it "applies base declarations onto the normal style" do
    screen = headless_screen
    button = Widget::Button.new
    screen.append button

    screen.stylesheet = "Button { color: red; background-color: blue; font-weight: bold; }"
    screen.apply_stylesheet

    button.styles.normal.fg.should eq rgb("red")
    button.styles.normal.bg.should eq rgb("blue")
    button.styles.normal.bold?.should be_true
  end

  it "layers :focus rules on top of base rules for the focused state" do
    screen = headless_screen
    button = Widget::Button.new
    screen.append button

    screen.stylesheet = <<-CSS
      Button { color: red; font-weight: bold; }
      Button:focus { color: green; }
    CSS
    screen.apply_stylesheet

    # base still applies in the focused state...
    button.styles.focused.bold?.should be_true
    # ...but the more specific :focus rule overrides color
    button.styles.focused.fg.should eq rgb("green")
    # normal state is unaffected by the :focus rule
    button.styles.normal.fg.should eq rgb("red")
  end

  it "matches the type chain so a base-class rule styles subclasses" do
    screen = headless_screen
    button = Widget::Button.new  # Button < Input
    check = Widget::CheckBox.new # CheckBox < Input
    screen.append button
    screen.append check

    screen.stylesheet = "Input { color: magenta; }"
    screen.apply_stylesheet

    button.styles.normal.fg.should eq rgb("magenta")
    check.styles.normal.fg.should eq rgb("magenta")
  end

  it "honors specificity (#id beats .class)" do
    screen = headless_screen
    button = Widget::Button.new
    button.css_id = "ok"
    screen.append button

    screen.stylesheet = <<-CSS
      Button { color: red; }
      #ok { color: blue; }
    CSS
    screen.apply_stylesheet

    button.styles.normal.fg.should eq rgb("blue")
  end

  it "inherits color down the tree where unset" do
    screen = headless_screen
    form = Widget::Form.new
    inner = Widget::Box.new # no rule of its own
    form.append inner
    screen.append form

    screen.stylesheet = "Form { color: yellow; }"
    screen.apply_stylesheet

    form.styles.normal.fg.should eq rgb("yellow")
    inner.styles.normal.fg.should eq rgb("yellow") # inherited
  end

  it "does not override colors that are explicitly set" do
    screen = headless_screen
    form = Widget::Form.new
    inner = Widget::Box.new
    form.append inner
    screen.append form

    screen.stylesheet = <<-CSS
      Form { color: yellow; }
      Box { color: red; }
    CSS
    screen.apply_stylesheet

    inner.styles.normal.fg.should eq rgb("red") # own rule wins over inheritance
  end

  it "routes sub-element rules into the matching sub-style without leaking" do
    screen = headless_screen
    box = Widget::Box.new
    box.scrollbar = true
    screen.append box

    screen.stylesheet = <<-CSS
      Box { color: white; }
      Scrollbar { color: cyan; }
    CSS
    screen.apply_stylesheet

    box.styles.normal.scrollbar.fg.should eq rgb("cyan")
    box.styles.normal.fg.should eq rgb("white") # main style untouched by scrollbar rule
  end

  it "parses padding and border shorthands" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = "Box { padding: 1 2 3 4; border: solid red; }"
    screen.apply_stylesheet

    pad = box.styles.normal.padding
    {pad.top, pad.right, pad.bottom, pad.left}.should eq({1, 2, 3, 4})

    border = box.styles.normal.border
    border.type.should eq BorderType::Line
    border.fg.should eq rgb("red")
    border.left.should eq 1 # solid border enables sides
  end

  it "only materializes states that have their own rules (others fall back to normal)" do
    screen = headless_screen
    base_only = Widget::Button.new # matched only by a base rule
    stateful = Widget::Button.new  # matched by a :focus rule
    base_only.css_id = "a"
    stateful.css_id = "b"
    screen.append base_only
    screen.append stateful

    screen.stylesheet = <<-CSS
      Button { color: red; }
      #b:focus { color: green; }
    CSS
    screen.apply_stylesheet

    # base-only widget: no distinct focused style was built; it lazily resolves
    # to normal
    base_only.styles.focused.should be base_only.styles.normal
    # stateful widget: a distinct focused style exists
    stateful.styles.focused.should_not be stateful.styles.normal
    stateful.styles.focused.fg.should eq rgb("green")
  end

  it "distinguishes :blurred from the :blur substring when peeling state" do
    screen = headless_screen
    button = Widget::Button.new
    screen.append button

    screen.stylesheet = "Button:blurred { color: red; }"
    screen.apply_stylesheet

    # The selector must peel to `Button` (not be corrupted to `Buttonred`
    # by stripping the shorter `:blur`), so the rule matches in the blurred state.
    button.styles.blurred.fg.should eq rgb("red")
  end

  it "maps opacity, tab-size and box-shadow" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = "Box { opacity: 0.5; tab-size: 8; box-shadow: 0.3; }"
    screen.apply_stylesheet

    style = box.styles.normal
    style.alpha.should eq 0.5
    style.tab_size.should eq 8
    style.shadow.right.should eq 2 # default drop shadow enabled
    style.shadow.alpha.should eq 0.3
  end

  it "disables the shadow with box-shadow: none" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = "Box { box-shadow: none; }"
    screen.apply_stylesheet

    box.styles.normal.shadow.right.should eq 0 # no shadow on any side
  end

  it "styles widgets via attribute selectors on intrinsic state" do
    screen = headless_screen
    on = Widget::CheckBox.new checked: true
    off = Widget::CheckBox.new checked: false
    screen.append on
    screen.append off

    screen.stylesheet = "CheckBox[checked] { color: red; }"
    screen.apply_stylesheet

    on.styles.normal.fg.should eq rgb("red")
    off.styles.normal.fg.should be_nil # unchecked box not matched
  end

  it "auto-invalidates styling when intrinsic state changes" do
    screen = headless_screen
    cb = Widget::CheckBox.new
    screen.append cb
    screen.stylesheet = "CheckBox[checked] { color: red; }"
    screen.apply_stylesheet
    screen.css_dirty?.should be_false

    cb.check
    screen.css_dirty?.should be_true # checked flip invalidated styling

    screen.apply_stylesheet
    cb.styles.normal.fg.should eq rgb("red")
  end

  it "auto-invalidates styling when classes, id or the tree change" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box
    screen.stylesheet = ".tagged { color: red; } #named { color: blue; }"
    screen.apply_stylesheet
    screen.css_dirty?.should be_false

    box.add_css_class "tagged"
    screen.css_dirty?.should be_true
    screen.apply_stylesheet
    box.styles.normal.fg.should eq rgb("red")

    screen.css_dirty?.should be_false
    box.css_id = "named"
    screen.css_dirty?.should be_true
    screen.apply_stylesheet
    box.styles.normal.fg.should eq rgb("blue") # #id now beats .class

    screen.css_dirty?.should be_false
    Widget::Box.new parent: screen # appending a widget re-dirties
    screen.css_dirty?.should be_true
  end

  it "supports sibling combinators and type-name selectors" do
    screen = headless_screen
    a = Widget::Box.new
    b = Widget::Button.new
    screen.append a
    screen.append b

    # `Box + Button` (type names + adjacent-sibling combinator) is rewritten to
    # `.Box + .Button` and matched against the document.
    screen.stylesheet = "Box + Button { color: red; }"
    screen.apply_stylesheet

    b.styles.normal.fg.should eq rgb("red")
    a.styles.normal.fg.should be_nil # the Box is the sibling, not the subject
  end

  it "lets !important override a more specific normal rule" do
    screen = headless_screen
    button = Widget::Button.new
    button.css_id = "x"
    screen.append button

    screen.stylesheet = <<-CSS
      #x { color: blue; }
      Button { color: red !important; }
    CSS
    screen.apply_stylesheet

    button.styles.normal.fg.should eq rgb("red") # !important beats #id specificity
  end

  it "resolves custom properties and var() with fallbacks" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = <<-CSS
      :root { --brand: cyan; }
      Box { color: var(--brand); background-color: var(--missing, magenta); }
    CSS
    screen.apply_stylesheet

    box.styles.normal.fg.should eq rgb("cyan")
    box.styles.normal.bg.should eq rgb("magenta") # fallback for undefined var
  end

  it "applies the default stylesheet beneath author rules" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    begin
      Crysterm::CSS.default_stylesheet = "Box { color: green; background-color: gray; }"
      screen.stylesheet = "Box { color: red; }" # overrides color only
      screen.apply_stylesheet

      box.styles.normal.fg.should eq rgb("red")  # author tier beats default tier
      box.styles.normal.bg.should eq rgb("gray") # default supplies what author omits
    ensure
      Crysterm::CSS.default_stylesheet = "" # reset global UA sheet
    end
  end

  it "folds inline @style above author rules but below !important" do
    screen = headless_screen
    button = Widget::Button.new style: Style.new(fg: "lime")
    screen.append button

    screen.stylesheet = "Button { color: red; background-color: blue; }"
    screen.apply_stylesheet

    # inline color beats the author rule; the author bg still applies since
    # inline didn't set one (per-property fold)
    button.styles.normal.fg.should eq rgb("lime")
    button.styles.normal.bg.should eq rgb("blue")
    # the getter returns the computed style (not the raw inline object)
    button.style.fg.should eq rgb("lime")
  end

  it "lets !important beat inline @style" do
    screen = headless_screen
    button = Widget::Button.new style: Style.new(fg: "lime")
    screen.append button

    screen.stylesheet = "Button { color: red !important; }"
    screen.apply_stylesheet

    button.styles.normal.fg.should eq rgb("red") # !important outranks inline
  end

  it "applies geometry and layout via CSS (onto the widget, not the style)" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = "Box { width: 40; height: 10; left: center; top: 5; text-align: center; }"
    screen.apply_stylesheet

    box.width.should eq 40 # bare int -> cells
    box.height.should eq 10
    box.left.should eq "center" # keyword -> passthrough string
    box.top.should eq 5
    box.align.should eq Tput::AlignFlag::HCenter
  end

  it "hides a widget with display: none" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = "Box { display: none; }"
    screen.apply_stylesheet

    box.styles.normal.visible?.should be_false
  end

  it "styles list items individually, including :nth-child" do
    screen = headless_screen
    list = Widget::List.new
    screen.append list
    list.set_items(["a", "b", "c", "d"])

    screen.stylesheet = <<-CSS
      List Box { color: white; }
      List Box:nth-child(even) { background-color: blue; }
    CSS
    screen.apply_stylesheet

    list.items.each { |item| item.styles.normal.fg.should eq rgb("white") }
    # items are children at positions 1..4, so :nth-child(even) hits #2 and #4
    list.items[0].styles.normal.bg.should be_nil
    list.items[1].styles.normal.bg.should eq rgb("blue")
    list.items[2].styles.normal.bg.should be_nil
    list.items[3].styles.normal.bg.should eq rgb("blue")
  end

  it "applies @media rules conditionally on terminal size" do
    screen = headless_screen
    screen.width = 100
    screen.height = 30
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = <<-CSS
      Box { color: white; }
      @media (min-width: 80) { Box { color: green; } }
      @media (min-width: 200) { Box { color: red; } }
    CSS
    screen.apply_stylesheet

    # width 100 satisfies min-width:80 (green) but not min-width:200 (red)
    box.styles.normal.fg.should eq rgb("green")
  end

  it "skips @media rules that do not match" do
    screen = headless_screen
    screen.width = 40
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = <<-CSS
      Box { color: white; }
      @media (min-width: 80) { Box { color: green; } }
    CSS
    screen.apply_stylesheet

    box.styles.normal.fg.should eq rgb("white") # 40 < 80, media rule skipped
  end

  it "supports per-side border longhands" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = "Box { border-top-width: 3; border-left: 2 solid; border-color: red; }"
    screen.apply_stylesheet

    border = box.styles.normal.border
    border.top.should eq 3
    border.left.should eq 2
    border.type.should eq BorderType::Line
    border.fg.should eq rgb("red")
  end

  it "resolves rgb(), hsl() and color keywords" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = "Box { color: rgb(255, 0, 128); background-color: hsl(120, 100%, 50%); border-color: transparent; }"
    screen.apply_stylesheet

    style = box.styles.normal
    style.fg.should eq 0xff0080
    style.bg.should eq 0x00ff00  # pure green
    style.border.fg.should eq -1 # transparent -> terminal default
  end

  it "collects diagnostics for malformed CSS and unknown properties" do
    sheet = Crysterm::CSS::Stylesheet.parse("Box { colour: red; width 10; }")
    sheet.warnings.any? { |w| w.includes?("unknown property") && w.includes?("colour") }.should be_true
    sheet.warnings.any?(&.includes?("malformed")).should be_true
  end

  it "supports ancestor-state pseudo-classes (Form:focus Button)" do
    screen = headless_screen
    form = Widget::Form.new
    button = Widget::Button.new
    form.append button
    screen.append form

    screen.stylesheet = <<-CSS
      Button { color: white; }
      Form:focus Button { color: green; }
    CSS
    screen.apply_stylesheet
    button.styles.normal.fg.should eq rgb("white") # form not focused

    # focusing the form invalidates styling (dynamic state) and the recascade
    # makes the ancestor-state rule match
    form.state = WidgetState::Focused
    screen.css_dirty?.should be_true
    screen.apply_stylesheet
    button.styles.normal.fg.should eq rgb("green")

    # blurring reverts it
    form.state = WidgetState::Normal
    screen.apply_stylesheet
    button.styles.normal.fg.should eq rgb("white")
  end

  it "lets inline @style force a boolean off over a stylesheet" do
    screen = headless_screen
    button = Widget::Button.new style: Style.new(bold: false)
    screen.append button

    screen.stylesheet = "Button { font-weight: bold; }"
    screen.apply_stylesheet

    # inline explicitly set bold:false, which now outranks the author rule
    button.styles.normal.bold?.should be_false
  end

  it "inherits font-weight, font-style and visibility down the tree" do
    screen = headless_screen
    form = Widget::Form.new
    inner = Widget::Box.new # no rule of its own
    form.append inner
    screen.append form

    screen.stylesheet = "Form { color: yellow; font-weight: bold; font-style: italic; }"
    screen.apply_stylesheet

    inner.styles.normal.fg.should eq rgb("yellow") # color inherits
    inner.styles.normal.bold?.should be_true       # font-weight inherits
    inner.styles.normal.italic?.should be_true     # font-style inherits
  end

  it "does not inherit a property the child explicitly sets" do
    screen = headless_screen
    form = Widget::Form.new
    inner = Widget::Box.new
    form.append inner
    screen.append form

    screen.stylesheet = <<-CSS
      Form { font-weight: bold; }
      Box { font-weight: normal; }
    CSS
    screen.apply_stylesheet

    inner.styles.normal.bold?.should be_false # own normal wins over inherited bold
  end

  it "wires bar/cell sub-element slots for more widgets" do
    screen = headless_screen
    pb = Widget::ProgressBar.new
    table = Widget::Table.new
    screen.append pb
    screen.append table

    screen.stylesheet = <<-CSS
      ProgressBar Bar { color: red; }
      Table Cell { background-color: blue; }
    CSS
    screen.apply_stylesheet

    pb.styles.normal.bar.fg.should eq rgb("red")
    table.styles.normal.cell.bg.should eq rgb("blue")
  end

  it "loads and reloads a stylesheet from a file" do
    path = File.tempname("crysterm-css", ".css")
    File.write(path, "Box { color: red; }")
    begin
      screen = headless_screen
      box = Widget::Box.new
      screen.append box

      screen.load_stylesheet path
      screen.apply_stylesheet
      box.styles.normal.fg.should eq rgb("red")

      File.write(path, "Box { color: blue; }")
      screen.reload_stylesheet
      screen.apply_stylesheet
      box.styles.normal.fg.should eq rgb("blue")
    ensure
      File.delete? path
    end
  end

  it "skips re-applying when the document is unchanged" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box
    screen.stylesheet = "Box { color: red; }"
    screen.apply_stylesheet

    # mutate the computed style directly, then re-apply with nothing changed:
    # the document is byte-identical, so the cascade is skipped and our mutation
    # survives (proving no recompute happened)
    box.styles.normal.fg = Crysterm::Colors.convert("green").to_i32
    screen.apply_stylesheet
    box.styles.normal.fg.should eq rgb("green")

    # a real change (new class) invalidates the document cache and recomputes
    screen.stylesheet = ".hot { color: red; }"
    box.add_css_class "hot"
    screen.apply_stylesheet
    box.styles.normal.fg.should eq rgb("red")
  end

  it "wires the label sub-element slot" do
    screen = headless_screen
    box = Widget::Box.new label: "hi"
    screen.append box

    screen.stylesheet = "Box Label { color: red; }"
    screen.apply_stylesheet

    box.styles.normal.label.fg.should eq rgb("red")
  end

  it "recomputes only the affected subtree (incremental invalidation)" do
    screen = headless_screen
    form1 = Widget::Form.new
    form2 = Widget::Form.new
    a = Widget::Box.new
    b = Widget::Box.new
    c = Widget::Box.new
    form1.append a
    form1.append b
    form2.append c
    screen.append form1
    screen.append form2

    screen.stylesheet = "Box { color: white; } .hot { color: red; }"
    screen.apply_stylesheet
    [a, b, c].each { |w| w.styles.normal.fg.should eq rgb("white") }

    # sentinels: if a widget is recomputed, the author rule overwrites these
    green = rgb("green")
    b.styles.normal.fg = green
    c.styles.normal.fg = green

    a.add_css_class "hot" # scope = subtree(a.parent = form1) = {form1, a, b}
    screen.apply_stylesheet

    a.styles.normal.fg.should eq rgb("red")   # a recomputed (.hot now matches)
    b.styles.normal.fg.should eq rgb("white") # b is in-scope (sibling) -> recomputed
    c.styles.normal.fg.should eq green        # c is out-of-scope -> NOT recomputed
  end

  it "does not leave a removed rule's value stale on re-cascade" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box
    screen.stylesheet = ".hot { color: red; }"
    box.add_css_class "hot"
    screen.apply_stylesheet
    box.styles.normal.fg.should eq rgb("red")

    box.remove_css_class "hot"
    screen.apply_stylesheet
    box.styles.normal.fg.should be_nil # rebuilt from pristine; red is gone
  end

  it "updates an inherited value when the ancestor's value changes" do
    screen = headless_screen
    form = Widget::Form.new
    inner = Widget::Box.new
    form.append inner
    screen.append form

    screen.stylesheet = <<-CSS
      Form { color: red; }
      .blue { color: blue; }
    CSS
    screen.apply_stylesheet
    inner.styles.normal.fg.should eq rgb("red") # inherited from form

    form.add_css_class "blue"
    screen.apply_stylesheet
    inner.styles.normal.fg.should eq rgb("blue") # re-inherits the new value, not stale red
  end

  it "supports per-side border colors" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = "Box { border: solid; border-top-color: red; border-bottom-color: blue; }"
    screen.apply_stylesheet

    border = box.styles.normal.border
    border.top_fg.should eq rgb("red")
    border.bottom_fg.should eq rgb("blue")
    border.left_fg.should eq border.fg # falls back to whole-border color
  end

  it "supports structural pseudo-classes" do
    screen = headless_screen
    form = Widget::Form.new
    a = Widget::Box.new
    b = Widget::Box.new
    c = Widget::Box.new
    form.append a
    form.append b
    form.append c
    screen.append form

    screen.stylesheet = <<-CSS
      Form Box:first-child { color: red; }
      Form Box:nth-child(2) { color: green; }
      Form Box:last-child { color: blue; }
    CSS
    screen.apply_stylesheet

    a.styles.normal.fg.should eq rgb("red")
    b.styles.normal.fg.should eq rgb("green")
    c.styles.normal.fg.should eq rgb("blue")
  end

  it "supports attribute operators including quoted values" do
    screen = headless_screen
    box = Widget::Box.new
    box.add_css_class "danger"
    screen.append box

    screen.stylesheet = <<-CSS
      [class*="dang"] { color: red; }
      [class$="state-normal"] { background-color: blue; }
    CSS
    screen.apply_stylesheet

    box.styles.normal.fg.should eq rgb("red")  # *= (contains)
    box.styles.normal.bg.should eq rgb("blue") # $= (ends-with, quoted — exercises the string fix)
  end

  it "keeps styling independent across multiple screens" do
    s1 = headless_screen
    s2 = headless_screen
    b1 = Widget::Box.new parent: s1
    b2 = Widget::Box.new parent: s2

    s1.stylesheet = "Box { color: red; }"
    s2.stylesheet = "Box { color: blue; }"
    s1.apply_stylesheet
    s2.apply_stylesheet

    b1.styles.normal.fg.should eq rgb("red")
    b2.styles.normal.fg.should eq rgb("blue")

    # a change + recascade on s1 must not touch s2's widget
    b2.styles.normal.fg = rgb("green") # sentinel
    b1.add_css_class "x"
    s1.apply_stylesheet
    b2.styles.normal.fg.should eq rgb("green")
  end

  it "handles CSS operations on a detached widget without crashing" do
    screen = headless_screen
    parent = Widget::Box.new parent: screen
    child = Widget::Box.new parent: parent

    screen.stylesheet = "Box { color: red; }"
    screen.apply_stylesheet
    child.styles.normal.fg.should eq rgb("red")

    parent.remove child
    child.screen?.should be_nil

    # CSS-relevant mutations are no-ops (not crashes) while detached
    child.add_css_class "x"
    child.css_id = "y"
    child.state = WidgetState::Focused

    # re-attaching brings it back under the cascade
    screen.stylesheet = "Box { color: blue; }"
    parent.append child
    screen.apply_stylesheet
    child.styles.normal.fg.should eq rgb("blue")
  end

  it "supports :has() (evaluated in the cascade, not html5)" do
    screen = headless_screen
    f1 = Widget::Form.new
    f2 = Widget::Form.new
    f1.append Widget::CheckBox.new # f1 has a checkbox descendant
    f2.append Widget::Box.new      # f2 doesn't
    screen.append f1
    screen.append f2

    screen.stylesheet = "Form:has(CheckBox) { color: red; }"
    screen.apply_stylesheet

    f1.styles.normal.fg.should eq rgb("red")
    f2.styles.normal.fg.should be_nil # :has must be subtree-scoped, not whole-document
  end

  it "stays consistent across attribute toggles (node patching, no re-parse)" do
    screen = headless_screen
    cb = Widget::CheckBox.new
    screen.append cb

    screen.stylesheet = <<-CSS
      CheckBox { color: white; }
      CheckBox[checked] { color: red; }
      .big { background-color: blue; }
    CSS
    screen.apply_stylesheet
    cb.styles.normal.fg.should eq rgb("white")

    cb.check # [checked] attribute now present (patched into the cached doc)
    screen.apply_stylesheet
    cb.styles.normal.fg.should eq rgb("red")

    cb.add_css_class "big" # class change (patched)
    screen.apply_stylesheet
    cb.styles.normal.fg.should eq rgb("red")
    cb.styles.normal.bg.should eq rgb("blue")

    cb.uncheck # [checked] removed again (patched)
    screen.apply_stylesheet
    cb.styles.normal.fg.should eq rgb("white") # [checked] no longer matches
    cb.styles.normal.bg.should eq rgb("blue")  # .big still matches
  end

  it "supports :has() with a child combinator" do
    screen = headless_screen
    f1 = Widget::Form.new # direct CheckBox child
    f2 = Widget::Form.new # CheckBox nested one level deeper
    f1.append Widget::CheckBox.new
    nested = Widget::Box.new
    nested.append Widget::CheckBox.new
    f2.append nested
    screen.append f1
    screen.append f2

    screen.stylesheet = "Form:has(> CheckBox) { color: red; }"
    screen.apply_stylesheet

    f1.styles.normal.fg.should eq rgb("red") # direct child checkbox
    f2.styles.normal.fg.should be_nil        # checkbox is a grandchild, not a direct child
  end

  it "computes per-cell styles for a table (Cell / Header / :nth-child)" do
    screen = headless_screen
    table = Widget::Table.new parent: screen, rows: [["A", "B"], ["1", "2"], ["3", "4"]]

    screen.stylesheet = <<-CSS
      Table Cell { color: white; }
      Header { background-color: blue; }
      Table Cell:nth-child(2) { color: red; }
    CSS
    screen.apply_stylesheet

    table.css_cell_style(1, 0).not_nil!.fg.should eq rgb("white") # all cells white
    table.css_cell_style(0, 0).not_nil!.bg.should eq rgb("blue")  # header row
    table.css_cell_style(1, 1).not_nil!.fg.should eq rgb("red")   # 2nd column
    table.css_cell_style(1, 0).not_nil!.fg.should eq rgb("white") # 1st column unaffected
  end

  it "leaves widgets untouched when no stylesheet is set" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box
    before = box.styles.normal.fg

    screen.apply_stylesheet # no stylesheet -> no-op

    box.styles.normal.fg.should eq before
  end
end
