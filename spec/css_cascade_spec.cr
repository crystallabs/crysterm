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

    screen.stylesheet = ".w-button { color: red; background-color: blue; font-weight: bold; }"
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
      .w-button { color: red; font-weight: bold; }
      .w-button:focus { color: green; }
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

    screen.stylesheet = ".w-input { color: magenta; }"
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
      .w-button { color: red; }
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

    screen.stylesheet = ".w-form { color: yellow; }"
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
      .w-form { color: yellow; }
      .w-box { color: red; }
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
      .w-box { color: white; }
      .w-scrollbar { color: cyan; }
    CSS
    screen.apply_stylesheet

    box.styles.normal.scrollbar.fg.should eq rgb("cyan")
    box.styles.normal.fg.should eq rgb("white") # main style untouched by scrollbar rule
  end

  it "parses padding and border shorthands" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = ".w-box { padding: 1 2 3 4; border: solid red; }"
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
      .w-button { color: red; }
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

    screen.stylesheet = ".w-button:blurred { color: red; }"
    screen.apply_stylesheet

    # The selector must peel to `.w-button` (not be corrupted to `.w-buttonred`
    # by stripping the shorter `:blur`), so the rule matches in the blurred state.
    button.styles.blurred.fg.should eq rgb("red")
  end

  it "maps opacity, tab-size and box-shadow" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = ".w-box { opacity: 0.5; tab-size: 8; box-shadow: 0.3; }"
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

    screen.stylesheet = ".w-box { box-shadow: none; }"
    screen.apply_stylesheet

    box.styles.normal.shadow.right.should eq 0 # no shadow on any side
  end

  it "styles widgets via attribute selectors on intrinsic state" do
    screen = headless_screen
    on = Widget::CheckBox.new checked: true
    off = Widget::CheckBox.new checked: false
    screen.append on
    screen.append off

    screen.stylesheet = ".w-checkbox[checked] { color: red; }"
    screen.apply_stylesheet

    on.styles.normal.fg.should eq rgb("red")
    off.styles.normal.fg.should be_nil # unchecked box not matched
  end

  it "auto-invalidates styling when intrinsic state changes" do
    screen = headless_screen
    cb = Widget::CheckBox.new
    screen.append cb
    screen.stylesheet = ".w-checkbox[checked] { color: red; }"
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

  it "leaves widgets untouched when no stylesheet is set" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box
    before = box.styles.normal.fg

    screen.apply_stylesheet # no stylesheet -> no-op

    box.styles.normal.fg.should eq before
  end
end
