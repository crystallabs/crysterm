require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# Runs *block* with the global default (user-agent) stylesheet emptied, then
# restores it. The auto-installed default theme would otherwise materialize
# extra state styles/base colors and break specs asserting cascade mechanics in
# isolation. Must run after the screen exists (auto-install would override an
# earlier reset).
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

    button.styles.focused.bold?.should be_true      # base still applies
    button.styles.focused.fg.should eq rgb("green") # :focus overrides color
    button.styles.normal.fg.should eq rgb("red")    # normal unaffected
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

  it "lets an inline sub-style outrank a sub-element rule (inline beats author/default)" do
    screen = headless_screen
    bar = Widget::ProgressBar.new style: Style.new(indicator: Style.new(fg: rgb("green")))
    screen.append bar

    screen.stylesheet = "ProgressBar::indicator { color: red; }"
    screen.apply_stylesheet

    # Inline (`TIER_INLINE`) outranks the author sub-element rule, same as the main style.
    bar.styles.normal.indicator.fg.should eq rgb("green")
  end

  it "folds a base sub-element rule into a state the parent widget materializes" do
    screen = headless_screen
    bar = Widget::ProgressBar.new
    screen.append bar
    bar.state = WidgetState::Focused

    # The base `::indicator` rule (no state of its own) must fold into the
    # materialized `:focus` state too, so a focused bar's indicator is themed
    # identically to an unfocused one — not reverted to pristine.
    screen.stylesheet = <<-CSS
      ProgressBar::indicator { color: cyan; }
      ProgressBar:focus { background-color: blue; }
      CSS
    screen.apply_stylesheet

    bar.styles.focused.indicator.fg.should eq rgb("cyan")
    bar.styles.normal.indicator.fg.should eq rgb("cyan")
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
    border.type.should eq BorderType::Solid
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

    without_default_theme do
      screen.stylesheet = <<-CSS
        Button { color: red; }
        #b:focus { color: green; }
        CSS
      screen.apply_stylesheet

      # base-only widget: no distinct focused style built, lazily resolves to normal
      base_only.styles.focused.should be base_only.styles.normal
      stateful.styles.focused.should_not be stateful.styles.normal # distinct style exists
      stateful.styles.focused.fg.should eq rgb("green")
    end
  end

  it "styles the unfocused look via :not(:focus)" do
    screen = headless_screen
    focused = Widget::Button.new
    unfocused = Widget::Button.new
    screen.append focused
    screen.append unfocused
    focused.focus

    # There is no "blurred" state/pseudo; the unfocused look is the standard
    # `:not(:focus)`, whose inner `:focus` lowers to `.state-focused` and is
    # matched against the live state classes stamped on the document.
    screen.stylesheet = "Button:not(:focus) { color: red; }"
    screen.apply_stylesheet

    unfocused.styles.normal.fg.should eq rgb("red")
    focused.styles.normal.fg.should_not eq rgb("red")
  end

  it "maps opacity, tab-size and box-shadow" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = "Box { opacity: 0.5; tab-size: 8; box-shadow: 0.3; }"
    screen.apply_stylesheet

    style = box.styles.normal
    style.opacity.should eq 0.5
    style.tab_size.should eq 8
    style.shadow.right.should eq 2 # default drop shadow enabled
    style.shadow.opacity.should eq 0.3
  end

  it "clamps an out-of-range opacity into [0, 1]" do
    screen = headless_screen
    hi = Widget::Box.new
    lo = Widget::Box.new
    hi.css_id = "hi"
    lo.css_id = "lo"
    screen.append hi
    screen.append lo

    # CSS clamps opacity; values above 1 / below 0 must not reach the blender.
    screen.stylesheet = "#hi { opacity: 2.0; } #lo { opacity: -0.5; }"
    screen.apply_stylesheet

    hi.styles.normal.opacity.should eq 1.0
    lo.styles.normal.opacity.should eq 0.0
  end

  it "keeps a real box-shadow visible when its offset is 0" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    # A `0` offset must not be read as alpha 0 — only a fractional number is opacity.
    screen.stylesheet = "Box { box-shadow: 0 4px 8px rgba(0,0,0,0.5); }"
    screen.apply_stylesheet

    style = box.styles.normal
    style.shadow.right.should eq 2     # default drop shadow enabled
    style.shadow.opacity.should eq 0.5 # default opacity, not 0
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

    # Isolate from the default theme, which sets a base text color on the unchecked box.
    without_default_theme do
      screen.stylesheet = "CheckBox[checked] { color: red; }"
      screen.apply_stylesheet

      on.styles.normal.fg.should eq rgb("red")
      off.styles.normal.fg.should be_nil # unchecked box not matched
    end
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

    # Type names + adjacent-sibling combinator rewrite to `.Box + .Button`.
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

  it "resolves a defined var() whose fallback holds a nested var()" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    # Outer `--brand` is defined, so the nested-var fallback is dropped. A
    # fallback parsed only to the first `)` would leave a stray `)` (`cyan)`),
    # an invalid color.
    screen.stylesheet = <<-CSS
      :root { --brand: cyan; }
      Box { color: var(--brand, var(--other, red)); }
      CSS
    screen.apply_stylesheet

    box.styles.normal.fg.should eq rgb("cyan")
  end

  it "applies the default stylesheet beneath author rules" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    saved = Crysterm::CSS.default_stylesheet
    begin
      Crysterm::CSS.default_stylesheet = "Box { color: green; background-color: gray; }"
      screen.stylesheet = "Box { color: red; }" # overrides color only
      screen.apply_stylesheet

      box.styles.normal.fg.should eq rgb("red")  # author tier beats default tier
      box.styles.normal.bg.should eq rgb("gray") # default supplies what author omits
    ensure
      # Restore the global UA sheet: other files' rendering specs rely on the
      # theme and run after this file.
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "folds inline @style above author rules but below !important" do
    screen = headless_screen
    button = Widget::Button.new style: Style.new(fg: "lime")
    screen.append button

    screen.stylesheet = "Button { color: red; background-color: blue; }"
    screen.apply_stylesheet

    # inline color beats the author rule; author bg still applies (per-property fold)
    button.styles.normal.fg.should eq rgb("lime")
    button.styles.normal.bg.should eq rgb("blue")
    button.style.fg.should eq rgb("lime") # getter returns computed style, not raw inline
  end

  it "lets !important beat inline @style" do
    screen = headless_screen
    button = Widget::Button.new style: Style.new(fg: "lime")
    screen.append button

    screen.stylesheet = "Button { color: red !important; }"
    screen.apply_stylesheet

    button.styles.normal.fg.should eq rgb("red") # !important outranks inline
  end

  it "carries inline-only Style fields (tab_size/tab_char/fill/draw_over_border) through the cascade" do
    screen = headless_screen
    inline = Style.new(fg: "lime")
    inline.tab_size = 8
    inline.tab_char = ">"
    inline.fill = false
    inline.draw_over_border = true
    box = Widget::Box.new style: inline
    screen.append box

    # An author rule not touching these fields must not drop inline-set values
    # during reset-and-recompute.
    screen.stylesheet = "Box { color: red; }"
    screen.apply_stylesheet

    normal = box.styles.normal
    normal.fg.should eq rgb("lime") # inline beats author color
    normal.tab_size.should eq 8
    normal.tab_char.should eq ">"
    normal.fill?.should be_false
    normal.draw_over_border?.should be_true
  end

  it "lets a CSS tab-size beat an inline tab_size, but inline beats author" do
    screen = headless_screen
    inline = Style.new
    inline.tab_size = 8
    box = Widget::Box.new style: inline
    screen.append box

    # Author tab-size loses to inline (inline folds at the inline tier)...
    screen.stylesheet = "Box { tab-size: 2; }"
    screen.apply_stylesheet
    box.styles.normal.tab_size.should eq 8

    # ...but !important beats inline.
    screen.stylesheet = "Box { tab-size: 3 !important; }"
    screen.apply_stylesheet
    box.styles.normal.tab_size.should eq 3
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

  it "matches text-align case-insensitively (CSS keyword values fold)" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    # A capitalized keyword must still apply.
    screen.stylesheet = "Box { text-align: CENTER; }"
    screen.apply_stylesheet
    box.align.should eq Tput::AlignFlag::HCenter

    screen.stylesheet = "Box { text-align: Right; }"
    screen.apply_stylesheet
    box.align.should eq Tput::AlignFlag::Right
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
    list.items = ["a", "b", "c", "d"]
    screen.stylesheet = <<-CSS
      List Box { color: white; }
      List Box:nth-child(even) { background-color: blue; }
      CSS
    screen.apply_stylesheet

    list.item_boxes.each(&.styles.normal.fg.should(eq(rgb("white"))))
    # items are children at positions 1..4, so :nth-child(even) hits #2 and #4
    list.item_boxes[0].styles.normal.bg.should be_nil
    list.item_boxes[1].styles.normal.bg.should eq rgb("blue")
    list.item_boxes[2].styles.normal.bg.should be_nil
    list.item_boxes[3].styles.normal.bg.should eq rgb("blue")
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
    border.type.should eq BorderType::Solid
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

    # focusing the form invalidates styling; recascade makes the ancestor-state rule match
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

  it "wires the indicator sub-element slot for bar widgets" do
    screen = headless_screen
    pb = Widget::ProgressBar.new
    slider = Widget::Slider.new
    screen.append pb
    screen.append slider

    screen.stylesheet = <<-CSS
      ProgressBar Indicator { color: red; }
      Slider Indicator { color: green; }
      CSS
    screen.apply_stylesheet

    pb.styles.normal.indicator.fg.should eq rgb("red")
    slider.styles.normal.indicator.fg.should eq rgb("green")
  end

  it "styles checkable widgets by Qt :checked/:unchecked/:indeterminate state via .qss" do
    path = File.tempname("crysterm-qss", ".qss")
    File.write(path, "QCheckBox:checked { color: red; }\n" \
                     "QCheckBox:unchecked { color: green; }\n" \
                     "QCheckBox:indeterminate { color: blue; }\n")
    begin
      screen = headless_screen
      on = Widget::CheckBox.new checked: true
      off = Widget::CheckBox.new checked: false
      tri = Widget::CheckBox.new tristate: true
      tri.partial
      screen.append on
      screen.append off
      screen.append tri
      screen.load_stylesheet path
      screen.apply_stylesheet
      on.style.fg.should eq rgb("red")
      off.style.fg.should eq rgb("green")
      tri.style.fg.should eq rgb("blue")
    ensure
      File.delete(path)
    end
  end

  it "styles checkable widgets by native :checked/:indeterminate (plain author CSS, no .qss)" do
    # Standard Selectors-L4 pseudos must work in ordinary CSS, not only via Qt translation.
    screen = headless_screen
    on = Widget::CheckBox.new checked: true
    off = Widget::CheckBox.new checked: false
    tri = Widget::CheckBox.new tristate: true
    tri.partial
    screen.append on
    screen.append off
    screen.append tri
    screen.stylesheet = "CheckBox:checked { color: red; }\n" \
                        "CheckBox:indeterminate { color: blue; }\n"
    screen.apply_stylesheet
    on.style.fg.should eq rgb("red")
    tri.style.fg.should eq rgb("blue")
    off.style.fg.should_not eq rgb("red") # unaffected
  end

  it "styles widgets by native :enabled (lowers to :not(:disabled)) in plain author CSS" do
    screen = headless_screen
    on = Widget::Button.new
    off = Widget::Button.new
    off.state = Crysterm::WidgetState::Disabled
    screen.append on
    screen.append off
    screen.stylesheet = "Button:enabled { color: green; }"
    screen.apply_stylesheet
    on.style.fg.should eq rgb("green")
    off.style.fg.should_not eq rgb("green")
  end

  it "styles widgets by Qt :horizontal/:vertical/:editable state via .qss" do
    path = File.tempname("crysterm-qss", ".qss")
    File.write(path, "QSlider:horizontal { color: red; }\n" \
                     "QSlider:vertical { color: green; }\n" \
                     "QComboBox:editable { color: blue; }\n")
    begin
      screen = headless_screen
      h = Widget::Slider.new orientation: Tput::Orientation::Horizontal
      v = Widget::Slider.new orientation: Tput::Orientation::Vertical
      c = Widget::ComboBox.new ["a", "b"], editable: true
      screen.append h
      screen.append v
      screen.append c
      screen.load_stylesheet path
      screen.apply_stylesheet
      h.style.fg.should eq rgb("red")
      v.style.fg.should eq rgb("green")
      c.style.fg.should eq rgb("blue")
    ensure
      File.delete(path)
    end
  end

  it "styles flat/default buttons by Qt :flat/:default state via .qss" do
    path = File.tempname("crysterm-qss", ".qss")
    File.write(path, "QPushButton:flat { color: red; }\n" \
                     "QPushButton:default { color: blue; }\n" \
                     "QGroupBox:flat { color: green; }\n")
    begin
      screen = headless_screen
      without_default_theme do
        flat = Widget::Button.new flat: true
        deflt = Widget::Button.new default: true
        plain = Widget::Button.new
        gb = Widget::GroupBox.new flat: true
        screen.append flat
        screen.append deflt
        screen.append plain
        screen.append gb
        screen.load_stylesheet path
        screen.apply_stylesheet
        flat.style.fg.should eq rgb("red")
        deflt.style.fg.should eq rgb("blue")
        gb.style.fg.should eq rgb("green")
        plain.style.fg.should be_nil # neither flat nor default → unmatched
      end
    ensure
      File.delete(path)
    end
  end

  it "strips a flat GroupBox's border via a [flat] { border: none } rule" do
    screen = headless_screen
    without_default_theme do
      framed = Widget::GroupBox.new title: "A"
      flat = Widget::GroupBox.new title: "B", flat: true
      screen.append framed
      screen.append flat
      screen.stylesheet = "GroupBox { border: solid; }\nGroupBox[flat] { border: none; }"
      screen.apply_stylesheet

      framed.style.border.top.should eq 1 # framed group keeps its border
      flat.style.border.top.should eq 0   # [flat] strips it
    end
  end

  it "routes a Qt ::chunk/::handle sub-control to the indicator slot via .qss" do
    path = File.tempname("crysterm-qss", ".qss")
    File.write(path, "QProgressBar::chunk { color: red; }\nQSlider::handle { color: green; }\n")
    begin
      screen = headless_screen
      pb = Widget::ProgressBar.new
      slider = Widget::Slider.new
      screen.append pb
      screen.append slider
      screen.load_stylesheet path
      screen.apply_stylesheet
      pb.styles.normal.indicator.fg.should eq rgb("red")
      slider.styles.normal.indicator.fg.should eq rgb("green")
    ensure
      File.delete(path)
    end
  end

  it "routes a native ::slot pseudo-element to its sub-style (plain author CSS, no .qss)" do
    # The idiomatic `Type::slot` spelling must resolve without Qt translation.
    screen = headless_screen
    pb = Widget::ProgressBar.new
    slider = Widget::Slider.new
    screen.append pb
    screen.append slider
    screen.stylesheet = "ProgressBar::indicator { color: red; }\nSlider::indicator { color: green; }\n"
    screen.apply_stylesheet
    pb.styles.normal.indicator.fg.should eq rgb("red")
    slider.styles.normal.indicator.fg.should eq rgb("green")
  end

  it "routes Menu::separator to the menu's separator sub-style" do
    screen = headless_screen
    menu = Widget::Menu.new
    menu.add_action "Open"
    menu.add_separator
    menu.add_action "Quit"
    screen.append menu
    screen.stylesheet = "Menu::separator { color: red; }"
    screen.apply_stylesheet
    menu.style.separator.fg.should eq rgb("red")
  end

  it "routes TabWidget::tab onto the bar's tabs (PreRender bridge)" do
    screen = headless_screen
    tabs = Widget::TabWidget.new width: 40, height: 10
    tabs.add_tab "One", Widget::Box.new
    tabs.add_tab "Two", Widget::Box.new
    screen.append tabs
    screen.stylesheet = "TabWidget::tab { color: red; }"
    screen.apply_stylesheet
    tabs.style.tab.fg.should eq rgb("red") # cascade computed the slot
    screen.repaint                         # PreRender pushes it onto each tab
    tabs.tab_bar.item_boxes.each(&.styles.normal.fg.should(eq(rgb("red"))))
  end

  it "leaves tabs at their default style when no TabWidget::tab rule matches" do
    screen = headless_screen
    tabs = Widget::TabWidget.new width: 40, height: 10
    tabs.add_tab "One", Widget::Box.new
    screen.append tabs
    screen.stylesheet = "Box { color: green; }" # unrelated rule
    screen.apply_stylesheet
    screen.repaint
    # `style.tab` falls back to `self`, so the bridge is a no-op.
    tabs.style.tab.same?(tabs.style).should be_true
  end

  it "routes GroupBox::title onto the title label (PreRender bridge)" do
    screen = headless_screen
    gb = Widget::GroupBox.new title: "Opts", width: 30, height: 8
    screen.append gb
    screen.stylesheet = "GroupBox::title { color: red; }"
    screen.apply_stylesheet
    gb.style.title.fg.should eq rgb("red")
    screen.repaint
    gb.@label_widget.not_nil!.styles.normal.fg.should eq rgb("red")
  end

  it "routes DockWidget::title onto the title bar" do
    screen = headless_screen
    dock = Widget::DockWidget.new title: "Files"
    screen.append dock
    screen.stylesheet = "DockWidget::title { color: red; }"
    screen.apply_stylesheet
    dock.style.title.fg.should eq rgb("red")
    screen.repaint
    dock.titlebar.styles.normal.fg.should eq rgb("red")
  end

  it "routes TabWidget::pane onto the current page" do
    screen = headless_screen
    tabs = Widget::TabWidget.new width: 40, height: 10
    page = Widget::Box.new
    tabs.add_tab "One", page
    screen.append tabs
    screen.stylesheet = "TabWidget::pane { background-color: blue; }"
    screen.apply_stylesheet
    tabs.style.pane.bg.should eq rgb("blue")
    screen.repaint
    page.styles.normal.bg.should eq rgb("blue")
  end

  it "routes DockWidget::close-button / ::float-button onto the title-bar buttons" do
    screen = headless_screen
    dock = Widget::DockWidget.new title: "Files"
    screen.append dock
    screen.stylesheet = "DockWidget::close-button { color: red; }\n" \
                        "DockWidget::float-button { color: green; }"
    screen.apply_stylesheet
    dock.style.close_button.fg.should eq rgb("red")
    dock.style.float_button.fg.should eq rgb("green")
    screen.repaint # PreRender pushes each onto its button box
    dock.@close_button.not_nil!.styles.normal.fg.should eq rgb("red")
    dock.@float_button.not_nil!.styles.normal.fg.should eq rgb("green")
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

    # Mutate the computed style, then re-apply with nothing changed: cascade is
    # skipped (byte-identical document) so the mutation survives.
    box.styles.normal.fg = Crysterm::Colors.convert("green").to_i32
    screen.apply_stylesheet
    box.styles.normal.fg.should eq rgb("green")

    # a real change (new class) invalidates the cache and recomputes
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
    [a, b, c].each(&.styles.normal.fg.should(eq(rgb("white"))))

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

  # The backward/only structural pseudos (`:last-child`, `:nth-last-child`, …)
  # match against a cached *structural* document (`to_html(structural: true)`,
  # sub-element pseudo-nodes omitted) reused across cascades. These lock that the
  # cache is invalidated correctly on child insert/remove — a stale structural
  # doc would keep styling the old last/nth-last child. A child carries a `label`
  # so the tree has a sub-element node, forcing the structural-document path.
  it "keeps :last-child / :nth-last-child correct after adding children (structural-doc cache)" do
    screen = headless_screen
    form = Widget::Form.new
    a = Widget::Box.new
    b = Widget::Box.new
    c = Widget::Box.new
    a.label = "x" # gives the tree an `::label` sub-element => structural-doc path
    form.append a
    form.append b
    form.append c
    screen.append form

    screen.stylesheet = <<-CSS
      Form Box:last-child { color: blue; }
      Form Box:nth-last-child(2) { color: green; }
      CSS
    screen.apply_stylesheet

    c.styles.normal.fg.should eq rgb("blue")  # last child
    b.styles.normal.fg.should eq rgb("green") # 2nd from last

    # Add a child: the last/nth-last positions shift. A stale cached structural
    # doc would keep c styled as the last child.
    d = Widget::Box.new
    form.append d
    screen.apply_stylesheet

    d.styles.normal.fg.should eq rgb("blue")     # new last child
    c.styles.normal.fg.should eq rgb("green")    # now 2nd from last
    c.styles.normal.fg.should_not eq rgb("blue") # no longer last
    b.styles.normal.fg.should_not eq rgb("green")
  end

  it "keeps :last-child / :nth-last-child correct after removing children (structural-doc cache)" do
    screen = headless_screen
    form = Widget::Form.new
    a = Widget::Box.new
    b = Widget::Box.new
    c = Widget::Box.new
    d = Widget::Box.new
    a.label = "x"
    form.append a
    form.append b
    form.append c
    form.append d
    screen.append form

    screen.stylesheet = <<-CSS
      Form Box:last-child { color: blue; }
      Form Box:nth-last-child(2) { color: green; }
      CSS
    screen.apply_stylesheet

    d.styles.normal.fg.should eq rgb("blue")
    c.styles.normal.fg.should eq rgb("green")

    # Remove the last child: c becomes the last child, b the 2nd from last.
    d.parent = nil
    screen.apply_stylesheet

    c.styles.normal.fg.should eq rgb("blue")
    b.styles.normal.fg.should eq rgb("green")
    c.styles.normal.fg.should_not eq rgb("green")
  end

  it "reuses the cached structural document when the tree is unchanged, rebuilds on change" do
    screen = headless_screen
    form = Widget::Form.new
    a = Widget::Box.new
    a.label = "x"
    form.append a
    form.append Widget::Box.new
    screen.append form
    screen.stylesheet = "Form Box:last-child { color: blue; }"
    screen.apply_stylesheet

    first = screen.css_structural_document
    # No structural change => byte-identical serialization => same parsed object.
    screen.css_structural_document.should be first
    # A structural change alters the serialization => a fresh parse.
    form.append Widget::Box.new
    screen.css_structural_document.should_not be first
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
    child.window?.should be_nil

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

  it "applies an ancestor-position :has() rule to the right widget" do
    without_default_theme do
      screen = headless_screen
      # f1's Button matches (Form ancestor has an .error descendant); f2's doesn't.
      f1 = Widget::Form.new
      err = Widget::Box.new
      err.add_css_class "error"
      b1 = Widget::Button.new
      f1.append err
      f1.append b1
      f2 = Widget::Form.new
      b2 = Widget::Button.new
      f2.append b2
      screen.append f1
      screen.append f2

      screen.stylesheet = "Form:has(.error) Button { color: red; }"
      screen.apply_stylesheet

      b1.styles.normal.fg.should eq rgb("red")
      b2.styles.normal.fg.should be_nil
    end
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

  it "supports :has() with sibling combinators (via :scope)" do
    screen = headless_screen
    form = Widget::Form.new
    a = Widget::Box.new
    b = Widget::CheckBox.new
    c = Widget::Box.new
    form.append a
    form.append b
    form.append c
    screen.append form

    screen.stylesheet = <<-CSS
      Box:has(+ CheckBox) { color: red; }
      Box:has(~ CheckBox) { background-color: blue; }
      CSS
    screen.apply_stylesheet

    a.styles.normal.fg.should eq rgb("red")  # immediately followed by a checkbox
    a.styles.normal.bg.should eq rgb("blue") # has a following-sibling checkbox
    c.styles.normal.fg.should be_nil         # no following checkbox
    c.styles.normal.bg.should be_nil
  end

  it "addresses ListTable rows individually" do
    screen = headless_screen
    lt = Widget::ListTable.new parent: screen, rows: [["H1", "H2"], ["a", "b"], ["c", "d"]]

    screen.stylesheet = <<-CSS
      ListTable Box { color: white; }
      ListTable Box:nth-child(2) { color: red; }
      CSS
    screen.apply_stylesheet

    lt.item_boxes[0].styles.normal.fg.should eq rgb("white")
    lt.item_boxes[1].styles.normal.fg.should eq rgb("red") # 2nd row
    lt.item_boxes[2].styles.normal.fg.should eq rgb("white")
  end

  it "supports font and background shorthands" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = "Box { font: bold italic; background: blue url(x.png) no-repeat; }"
    screen.apply_stylesheet

    style = box.styles.normal
    style.bold?.should be_true
    style.italic?.should be_true
    style.bg.should eq rgb("blue") # color pulled out of the background shorthand
  end

  it "supports native nesting (descendant and &)" do
    screen = headless_screen
    form = Widget::Form.new
    button = Widget::Button.new
    form.append button
    screen.append form

    screen.stylesheet = <<-CSS
      Form {
        color: white;
        Button { color: red; }
        &.active { background-color: blue; }
      }
      CSS
    form.add_css_class "active"
    screen.apply_stylesheet

    form.styles.normal.fg.should eq rgb("white") # Form's own declaration
    form.styles.normal.bg.should eq rgb("blue")  # &.active -> Form.active
    button.styles.normal.fg.should eq rgb("red") # nested "Form Button"
  end

  it "orders rules by @layer (later layers win, unlayered wins over all)" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = <<-CSS
      @layer base, theme;
      @layer theme { Box { color: green; } }
      @layer base  { Box { color: red; } }
      CSS
    screen.apply_stylesheet
    # theme is declared after base, so theme wins even though its rule appears first
    box.styles.normal.fg.should eq rgb("green")

    screen.stylesheet = <<-CSS
      @layer theme { Box { color: green; } }
      Box { color: magenta; }
      CSS
    screen.apply_stylesheet
    box.styles.normal.fg.should eq rgb("magenta") # unlayered beats any layer
  end

  it "supports @import" do
    dir = File.tempname("crysterm-import")
    Dir.mkdir dir
    File.write File.join(dir, "base.css"), "Box { color: red; background-color: gray; }"
    main = File.join(dir, "main.css")
    File.write main, %(@import "base.css";\nBox { color: blue; })
    begin
      screen = headless_screen
      box = Widget::Box.new
      screen.append box

      screen.load_stylesheet main
      screen.apply_stylesheet

      box.styles.normal.fg.should eq rgb("blue") # importing file overrides import
      box.styles.normal.bg.should eq rgb("gray") # imported value where not overridden
    ensure
      File.delete? File.join(dir, "base.css")
      File.delete? main
      Dir.delete(dir) rescue nil
    end
  end

  it "computes per-cell styles for a ListTable" do
    screen = headless_screen
    lt = Widget::ListTable.new parent: screen, rows: [["H1", "H2"], ["a", "b"], ["c", "d"]]

    screen.stylesheet = <<-CSS
      ListTable Cell { color: white; }
      Header { background-color: blue; }
      ListTable Cell:nth-child(2) { color: red; }
      CSS
    screen.apply_stylesheet

    lt.css_cell_style(1, 0).not_nil!.fg.should eq rgb("white")
    lt.css_cell_style(0, 0).not_nil!.bg.should eq rgb("blue") # header row
    lt.css_cell_style(1, 1).not_nil!.fg.should eq rgb("red")  # 2nd column
  end

  it "preserves a widget hidden before the first cascade" do
    # Regression: a widget hidden at construction must stay hidden once CSS
    # takes over. The cascade used to rebuild from a `visible: true` snapshot
    # and `fold_inline` didn't carry `visible`.
    screen = headless_screen
    box = Widget::Box.new parent: screen, style: Style.new(border: true)
    box.hide
    box.visible?.should be_false

    screen.stylesheet = "Box { color: white; }"
    screen.apply_stylesheet

    box.css_styled?.should be_true
    box.visible?.should be_false
  end

  it "keeps an imperative show/hide across a recascade" do
    # Once `css_styled`, show/hide persist onto the inline style so a later
    # cascade (reset to base snapshot + fold inline) doesn't revert it.
    screen = headless_screen
    box = Widget::Box.new parent: screen, style: Style.new(border: true)
    box.hide

    screen.stylesheet = "Box { color: white; }"
    screen.apply_stylesheet
    box.visible?.should be_false

    box.show
    box.visible?.should be_true

    # Force a fresh full cascade; the shown state must survive it.
    screen.restyle
    screen.apply_stylesheet
    box.visible?.should be_true
  end

  it "leaves widgets untouched when no stylesheet is set" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box
    before = box.styles.normal.fg

    screen.apply_stylesheet # no stylesheet -> no-op

    box.styles.normal.fg.should eq before
  end

  it "maps alternate-background-color onto the alternate_row sub-style" do
    screen = headless_screen
    table = Widget::ListTable.new
    screen.append table

    without_default_theme do
      screen.stylesheet = "ListTable { color: red; alternate-background-color: blue; }"
      screen.apply_stylesheet

      style = table.styles.normal
      style.alternate_row.bg.should eq rgb("blue") # alternate row gets its own bg
      style.bg.should be_nil                       # doesn't leak into main/cell style
      style.cell.bg.should be_nil
      style.fg.should eq rgb("red") # main foreground unaffected
    end
  end

  it "maps selection-color/-background-color onto the selected state" do
    screen = headless_screen
    list = Widget::List.new
    screen.append list

    without_default_theme do
      screen.stylesheet = <<-CSS
        List { color: white; background-color: black;
               selection-color: yellow; selection-background-color: magenta; }
        CSS
      screen.apply_stylesheet

      # Selection colors land on the selected state, not normal.
      list.styles.selected.fg.should eq rgb("yellow")
      list.styles.selected.bg.should eq rgb("magenta")
      list.styles.normal.fg.should eq rgb("white") # base color folded into selected
      list.styles.normal.bg.should eq rgb("black")
      list.styles.selected.should_not be list.styles.normal # distinct style materialized
    end
  end

  it "lets an explicit higher-specificity :selected rule win over selection-*" do
    screen = headless_screen
    list = Widget::List.new
    list.css_id = "lst"
    screen.append list

    without_default_theme do
      screen.stylesheet = <<-CSS
        List { selection-background-color: magenta; }
        #lst:selected { background-color: green; }
        CSS
      screen.apply_stylesheet

      list.styles.selected.bg.should eq rgb("green") # id selector wins
    end
  end
end

describe "CSS::Specificity" do
  spec = ->(s : String) { Crysterm::CSS::Specificity.calculate(s) }

  it "counts ids, classes/attrs/pseudos, and types" do
    spec.call("#id").should eq({1, 0, 0})
    spec.call(".cls").should eq({0, 1, 0})
    spec.call("[attr]").should eq({0, 1, 0})
    spec.call(":hover").should eq({0, 1, 0})
    spec.call("Box").should eq({0, 0, 1})
    spec.call("::before").should eq({0, 0, 1})
    spec.call("Form #id .cls Button").should eq({1, 1, 2})
  end

  it "takes the MAX (not sum) of a functional pseudo-class's argument list" do
    # :is()/:not()/:has() contribute the specificity of their most specific
    # argument, comparing each argument's (a, b, c) tuple — not the sum.
    spec.call(":is(.a, #b)").should eq({1, 0, 0})       # #b wins, not (1,1,0)
    spec.call(":not(.a, .b, .c)").should eq({0, 1, 0})  # one class, not three
    spec.call(":has(.a, Box Box)").should eq({0, 1, 0}) # .a (0,1,0) > two types (0,0,2)
    # Combined with surrounding simple selectors, the max is just added in.
    spec.call("Button:is(.a, #b)").should eq({1, 0, 1})
  end

  it "treats :where() as contributing zero specificity" do
    spec.call(":where(#a, .b, Box)").should eq({0, 0, 0})
    spec.call("Button:where(#big)").should eq({0, 0, 1})
  end
end

describe "CSS::ColorValue" do
  it "resolves rgb()/rgba() with 0..255 components" do
    Crysterm::CSS::ColorValue.resolve("rgb(255, 0, 0)", nil).should eq 0xff0000
    Crysterm::CSS::ColorValue.resolve("rgb(10, 20, 30)", nil).should eq 0x0a141e
    # Alpha is ignored.
    Crysterm::CSS::ColorValue.resolve("rgba(0, 255, 0, 0.5)", nil).should eq 0x00ff00
  end

  it "scales rgb()/rgba() percentage components to 0..255" do
    Crysterm::CSS::ColorValue.resolve("rgb(100%, 0%, 0%)", nil).should eq 0xff0000
    Crysterm::CSS::ColorValue.resolve("rgb(0%, 100%, 0%)", nil).should eq 0x00ff00
    Crysterm::CSS::ColorValue.resolve("rgba(0%, 0%, 100%, 0.5)", nil).should eq 0x0000ff
  end

  it "resolves hsl() and wraps a negative hue" do
    Crysterm::CSS::ColorValue.resolve("hsl(120, 100%, 50%)", nil).should eq 0x00ff00 # green
    Crysterm::CSS::ColorValue.resolve("hsl(240, 100%, 50%)", nil).should eq 0x0000ff # blue
    # A negative hue wraps: -120 ≡ 240 (blue), not |−120| = 120.
    Crysterm::CSS::ColorValue.resolve("hsl(-120, 100%, 50%)", nil).should eq 0x0000ff
    Crysterm::CSS::ColorValue.resolve("hsl(-240, 100%, 50%)", nil).should eq 0x00ff00
  end

  it "resolves color functions case-insensitively (CSS names are case-insensitive)" do
    Crysterm::CSS::ColorValue.resolve("RGB(255, 0, 0)", nil).should eq 0xff0000
    Crysterm::CSS::ColorValue.resolve("RGBA(0, 255, 0, 0.5)", nil).should eq 0x00ff00
    Crysterm::CSS::ColorValue.resolve("HSL(240, 100%, 50%)", nil).should eq 0x0000ff
  end

  # --- Case-insensitivity of the remaining CSS token classes ---

  it "matches property names case-insensitively (CSS property names are case-insensitive)" do
    style = Crysterm::Style.new
    Crysterm::CSS::Properties.apply(style, "COLOR", "red")
    style.fg.should eq rgb("red")
    # mixed-case longhand, including the `border*` family
    border_style = Crysterm::Style.new
    Crysterm::CSS::Properties.apply(border_style, "Border-Width", "3")
    border_style.border.left.should eq 3
  end

  it "matches keyword values case-insensitively (none/hidden/border keywords)" do
    none = Crysterm::Style.new
    Crysterm::CSS::Properties.apply(none, "display", "NONE")
    none.visible?.should be_false

    hidden = Crysterm::Style.new
    Crysterm::CSS::Properties.apply(hidden, "visibility", "Hidden")
    hidden.visible?.should be_false

    # `DASHED` differs from the default `Line`, proving the keyword matched.
    bordered = Crysterm::Style.new
    Crysterm::CSS::Properties.apply(bordered, "border", "DASHED")
    bordered.border.type.should eq Crysterm::BorderType::Dashed

    # `font-weight: BOLD` (bool keyword) still turns on bold
    weighted = Crysterm::Style.new
    Crysterm::CSS::Properties.apply(weighted, "font-weight", "BOLD")
    weighted.bold?.should be_true
  end

  it "honors numeric and relative font-weight values (Qt: bold is weight > 500)" do
    # Numeric weights: > 500 is bold (Qt's QFont#bold cutoff), <= 500 is not.
    {700, 600, 800, 900, 501}.each do |w|
      st = Crysterm::Style.new
      Crysterm::CSS::Properties.apply(st, "font-weight", w.to_s)
      st.bold?.should be_true
    end
    {100, 400, 500}.each do |w|
      st = Crysterm::Style.new
      st.bold = true # start bold so we prove the property turns it back off
      Crysterm::CSS::Properties.apply(st, "font-weight", w.to_s)
      st.bold?.should be_false
    end

    # Relative keywords map to the binary attribute.
    bolder = Crysterm::Style.new
    Crysterm::CSS::Properties.apply(bolder, "font-weight", "bolder")
    bolder.bold?.should be_true

    lighter = Crysterm::Style.new
    lighter.bold = true
    Crysterm::CSS::Properties.apply(lighter, "font-weight", "lighter")
    lighter.bold?.should be_false

    # An unrecognized value leaves the current weight untouched.
    keep = Crysterm::Style.new
    keep.bold = true
    Crysterm::CSS::Properties.apply(keep, "font-weight", "garbage")
    keep.bold?.should be_true
  end

  it "resolves var() case-insensitively, but the custom-property name stays case-sensitive" do
    vars = {"--accent" => "red"}
    Crysterm::CSS::Stylesheet.resolve_var("VAR(--accent)", vars).should eq "red"
    Crysterm::CSS::Stylesheet.resolve_var("Var(--accent)", vars).should eq "red"
    # `--Accent` is undefined (case-sensitive), so it falls back to empty.
    Crysterm::CSS::Stylesheet.resolve_var("var(--Accent)", vars).should eq ""
  end

  it "parses at-rule names case-insensitively (@MEDIA/@LAYER/@IMPORT)" do
    sheet = Crysterm::CSS::Stylesheet.parse("@MEDIA (min-width: 1) { Button { color: red; } }")
    sheet.rules.size.should eq 1
    sheet.rules.first.media.should_not be_nil
    sheet.rules.first.selector.should contain("Button")
  end

  it "matches viewport units case-insensitively (CSS units are case-insensitive)" do
    Crysterm::CSS::Length.viewport?("10VW").should be_true
    Crysterm::CSS::Length.viewport?("10VMIN").should be_true
    Crysterm::CSS::Length.viewport_cells("50VW", 80, 24).should eq 40
    # same answer as the lowercase form
    Crysterm::CSS::Length.viewport_cells("50vw", 80, 24).should eq 40
  end

  it "peels a state pseudo-class case-insensitively (:FOCUS == :focus)" do
    screen = headless_screen
    button = Widget::Button.new
    screen.append button
    without_default_theme do
      screen.stylesheet = <<-CSS
        Button { color: red; }
        Button:FOCUS { color: green; }
        CSS
      screen.apply_stylesheet
      button.styles.normal.fg.should eq rgb("red")
      button.styles.focused.fg.should eq rgb("green")
    end
  end

  it "keeps type selectors case-sensitive (lowercase `button` does not match a Button)" do
    screen = headless_screen
    button = Widget::Button.new
    screen.append button
    without_default_theme do
      # Type/widget names are case-sensitive unlike CSS keywords.
      screen.stylesheet = "button { color: red; }"
      screen.apply_stylesheet
      button.styles.normal.fg.should be_nil

      # Correctly-cased `Button` does match.
      screen.stylesheet = "Button { color: red; }"
      screen.apply_stylesheet
      button.styles.normal.fg.should eq rgb("red")
    end
  end
end
