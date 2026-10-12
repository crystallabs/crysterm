require "./spec_helper"

include Crysterm

# The patch-only cascade: a state flip (or any other attribute-only change)
# under ancestor-state rules patches the cached CSS document in place and
# re-matches only the rules that mention a changed token, instead of
# re-serializing the tree and re-matching every rule. Every step below is
# checked against a control window driven only by full recomputes
# (`restyle`), so the fast path must land on byte-identical computed styles
# and geometry.

private SHEET = <<-CSS
  Button { background-color: #333344; color: #ddddee; }
  Label { color: #aaaaaa; }
  Box > Label { font-weight: bold; }
  Box:hover > Label { color: #0000ff; }
  Button:focus ~ Label { color: #00ff00; background-color: #101010; }
  Button:not(:focus) ~ LineEdit { color: #777777; }
  CheckBox[checked] ~ Label { font-style: italic; }
  .hot Button { background-color: #ff0000; }
  Form Box:hover Button { color: #ff00ff; width: 5; }
  CSS

private record Tree,
  window : Window,
  boxes : Array(Widget::Box),
  labels : Array(Widget::Label),
  buttons : Array(Widget::Button),
  edits : Array(Widget::LineEdit),
  checks : Array(Widget::CheckBox),
  all : Array(Widget)

private def build_tree(sheet : String = SHEET) : Tree
  s = headless_screen(80, 24)
  boxes = [] of Widget::Box
  labels = [] of Widget::Label
  buttons = [] of Widget::Button
  edits = [] of Widget::LineEdit
  checks = [] of Widget::CheckBox
  all = [] of Widget
  2.times do |f|
    form = Widget::Form.new parent: s, top: f * 12, left: 0, width: 80, height: 12
    all << form
    3.times do |b|
      box = Widget::Box.new parent: form, top: b * 4, left: 0, width: 80, height: 4
      all << box
      boxes << box
      btn = Widget::Button.new parent: box, top: 0, left: 0, width: 8, height: 1, text: "b"
      all << btn
      buttons << btn
      chk = Widget::CheckBox.new parent: box, top: 0, left: 10, width: 8, height: 1, text: "c"
      all << chk
      checks << chk
      lbl = Widget::Label.new parent: box, top: 1, left: 0, width: 10, height: 1, text: "l"
      all << lbl
      labels << lbl
      le = Widget::LineEdit.new parent: box, top: 2, left: 0, width: 10, height: 1
      all << le
      edits << le
      inner = Widget::Box.new parent: box, top: 3, left: 0, width: 20, height: 1
      all << inner
      boxes << inner
      l2 = Widget::Label.new parent: inner, top: 0, left: 0, width: 5, height: 1, text: "x"
      all << l2
      labels << l2
      b2 = Widget::Button.new parent: inner, top: 0, left: 6, width: 5, height: 1, text: "y"
      all << b2
      buttons << b2
    end
  end
  s.stylesheet = sheet
  s.apply_stylesheet
  Tree.new s, boxes, labels, buttons, edits, checks, all
end

# A value signature of everything the cascade writes onto one `Style`.
private def style_sig(st : Style) : String
  String.build do |io|
    io << st.fg << '/' << st.bg << '/' << st.bold? << st.italic? << st.underline? << st.reverse? << st.visible?
    io << '/' << st.specified?(:fg) << st.specified?(:bg) << st.specified?(:bold) << st.specified?(:italic)
    io << '/' << st.border.left << st.border.top << st.padding.left << st.padding.top
    io << '/' << st.offset_x << ',' << st.offset_y
  end
end

# Signature of a widget's computed per-state styles, `css_styled?` flag and
# CSS-writable geometry.
private def widget_sig(w : Widget) : String
  String.build do |io|
    io << w.css_styled? << '|'
    io << style_sig(w.styles.normal)
    {% for state in %w[focused hovered selected disabled] %}
      io << '|' << (w.styles.own_{{ state.id }}? ? style_sig(w.styles.{{ state.id }}) : "-")
    {% end %}
    io << '|' << w.width_spec.inspect << '|' << w.state
  end
end

private def tree_sig(t : Tree) : Array(String)
  t.all.map { |w| widget_sig w }
end

# Runs *step* on both trees; the fast-path tree then cascades as a repaint
# would (`apply_stylesheet`), the control tree is forced through a full
# recompute. The two must agree on every widget.
private def check_step(fast : Tree, control : Tree, label : String, &step : Tree -> Nil)
  step.call fast
  step.call control
  fast.window.apply_stylesheet
  control.window.restyle
  control.window.apply_stylesheet
  fs = tree_sig(fast)
  cs = tree_sig(control)
  fs.each_with_index do |sig, i|
    sig.should eq(cs[i]), "#{label}: widget ##{i} (#{fast.all[i].class}) differs\n  fast:    #{sig}\n  control: #{cs[i]}"
  end
end

describe "CSS patch-only cascade on a state flip" do
  it "dirties the cascade only under ancestor-state rules" do
    t = build_tree
    t.window.css_dynamic_state?.should be_true
  end

  it "matches a full recompute across hover, focus, checked, class, geometry and structural steps" do
    fast = build_tree
    control = build_tree
    patched0 = fast.window.css_cascades_patched
    serialized0 = fast.window.css_cascades_serialized

    # Hover a box: `Box:hover > Label` colors its direct label, `Form Box:hover
    # Button` recolors and resizes its buttons.
    check_step(fast, control, "hover box") { |t| t.boxes[0].state = :hovered }
    fast.window.css_cascades_patched.should eq patched0 + 1
    fast.window.css_cascades_serialized.should eq serialized0

    # Hover an inner box (its parent is a box too).
    check_step(fast, control, "hover inner box") { |t| t.boxes[1].state = :hovered }
    check_step(fast, control, "unhover inner box") { |t| t.boxes[1].state = :normal }
    check_step(fast, control, "unhover box") { |t| t.boxes[0].state = :normal }

    # A flip that affects nothing: a label's own hover matches no rule.
    check_step(fast, control, "hover label") { |t| t.labels[0].state = :hovered }
    check_step(fast, control, "unhover label") { |t| t.labels[0].state = :normal }

    # Focus moves between buttons: `Button:focus ~ Label` / `:not(:focus) ~
    # LineEdit` on the siblings of both the blurred and the focused one.
    check_step(fast, control, "focus button 0") { |t| t.buttons[0].focus }
    check_step(fast, control, "focus button 2") { |t| t.buttons[2].focus }
    check_step(fast, control, "focus inner button") { |t| t.buttons[1].focus }

    # Hover while focused elsewhere, then a same-frame flip and flip back
    # (nothing changes — the document is as it was).
    check_step(fast, control, "hover box while focused") { |t| t.boxes[2].state = :hovered }
    check_step(fast, control, "flip and flip back") do |t|
      t.boxes[4].state = :hovered
      t.boxes[4].state = :normal
    end
    check_step(fast, control, "unhover") { |t| t.boxes[2].state = :normal }

    # An intrinsic attribute: `CheckBox[checked] ~ Label`. The label after the
    # box is the one sibling it reaches (the inner box's label is not a
    # sibling), and both sides must actually flip, not merely agree.
    fast.labels[0].styles.normal.italic?.should be_false
    check_step(fast, control, "check") { |t| t.checks[0].checked = true }
    {fast, control}.each do |t|
      t.labels[0].styles.normal.italic?.should be_true
      t.labels[1].styles.normal.italic?.should be_false
      t.labels[2].styles.normal.italic?.should be_false
    end
    check_step(fast, control, "uncheck") { |t| t.checks[0].checked = false }
    {fast, control}.each { |t| t.labels[0].styles.normal.italic?.should be_false }

    # A user class on an ancestor: `.hot Button`.
    check_step(fast, control, "add class") { |t| t.boxes[2].add_css_class "hot" }
    check_step(fast, control, "remove class") { |t| t.boxes[2].remove_css_class "hot" }

    # A geometry write between flips (not a styling change; must survive the
    # next cascade on both sides).
    check_step(fast, control, "geometry then hover") do |t|
      t.labels[2].width = 7
      t.boxes[2].state = :hovered
    end
    fast.window.css_cascades_serialized.should eq serialized0

    # A structural change: a new label under the hovered box takes the slow,
    # serializing route and must land on the same result.
    check_step(fast, control, "append under hovered box") do |t|
      lbl = Widget::Label.new parent: t.boxes[2], top: 1, left: 12, width: 5, height: 1, text: "n"
      t.all << lbl
    end
    fast.window.css_cascades_serialized.should eq serialized0 + 1
    check_step(fast, control, "hover after structural") { |t| t.boxes[2].state = :normal }
    check_step(fast, control, "hover again") { |t| t.boxes[2].state = :hovered }

    # A stylesheet swap re-serializes; flips afterwards patch again.
    check_step(fast, control, "sheet swap") { |t| t.window.stylesheet = SHEET + "\nLabel { background-color: #202020; }" }
    check_step(fast, control, "hover after swap") { |t| t.boxes[3].state = :hovered }
    check_step(fast, control, "unhover after swap") { |t| t.boxes[3].state = :normal }
  end

  it "takes the serializing route under relational rules and still agrees" do
    sheet = SHEET + "\nBox:has(Button:focus) Label { color: #123456; }"
    fast = build_tree sheet
    control = build_tree sheet
    fast.window.css_has_relational?.should be_true
    serialized0 = fast.window.css_cascades_serialized
    check_step(fast, control, "focus under :has") { |t| t.buttons[3].focus }
    check_step(fast, control, "hover under :has") { |t| t.boxes[1].state = :hovered }
    fast.window.css_cascades_serialized.should eq serialized0 + 2
  end

  it "patches an attribute flipped back into the cached document before a serializing cascade" do
    fast = build_tree
    control = build_tree
    # Adding the class takes the patch route, leaving the cached nodes ahead
    # of the last serialized string. Removing it arrives together with a
    # sheet swap: the serializing route must still patch the node, although
    # the tree now serializes to the very string last parsed — or `.hot
    # Button` keeps matching the buttons under the box.
    patched0 = fast.window.css_cascades_patched
    check_step(fast, control, "add class") { |t| t.boxes[2].add_css_class "hot" }
    fast.window.css_cascades_patched.should eq patched0 + 1
    check_step(fast, control, "remove class with sheet swap") do |t|
      t.boxes[2].remove_css_class "hot"
      t.window.stylesheet = SHEET + "\nLabel { background-color: #202020; }"
    end
    fast.buttons[2].styles.normal.bg.should eq 0x333344
  end

  it "skips the cascade when a flip and its reversal leave the document unchanged" do
    t = build_tree
    patched0 = t.window.css_cascades_patched
    serialized0 = t.window.css_cascades_serialized
    t.boxes[0].state = :hovered
    t.boxes[0].state = :normal
    t.window.apply_stylesheet
    t.window.css_cascades_patched.should eq patched0
    t.window.css_cascades_serialized.should eq serialized0
    t.window.css_dirty?.should be_false
  end
end
