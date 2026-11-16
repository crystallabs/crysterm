require "./spec_helper"

include Crysterm

private def xsel(c, fmt, full = false)
  Widget::TextEdit::ExtraSelection.new(c, fmt, full_width: full)
end

private def damage_window(damage : Bool)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24,
    optimization: damage ? Crysterm::OptimizationFlag::DamageTracking : Crysterm::OptimizationFlag::None)
end

private def assert_same_cells(a : Crysterm::Window, b : Crysterm::Window, ctx : String)
  a.cell_rows.size.should eq b.cell_rows.size
  a.cell_rows.each_index do |y|
    la = a.cell_rows[y]
    lb = b.cell_rows[y]
    la.size.times do |x|
      if la[x].attr != lb[x].attr || la[x].char != lb[x].char
        fail "cell mismatch at (#{y},#{x}) #{ctx}: damage=#{la[x].char.inspect} full=#{lb[x].char.inspect}"
      end
    end
  end
end

# A tiling of 2x1 top-level boxes: 40 columns x 12 rows = 480 roots.
private def tile(s : Crysterm::Window) : Array(Widget::Box)
  boxes = [] of Widget::Box
  12.times do |y|
    40.times do |x|
      boxes << Widget::Box.new(parent: s, top: y, left: x * 2, width: 2, height: 1, content: "ab")
    end
  end
  boxes
end

private STATE_SHEET = <<-CSS
  Label { color: #aaaaaa; }
  Form:hover Label { color: #0000ff; }
  .hot Label { color: #ff0000; }
  CSS

private def css_tree(sheet : String)
  s = headless_screen(60, 20)
  labels = [] of Widget::Label
  forms = [] of Widget::Form
  2.times do |f|
    form = Widget::Form.new parent: s, top: f * 10, left: 0, width: 60, height: 10
    forms << form
    2.times do |i|
      labels << Widget::Label.new(parent: form, top: i, left: 0, width: 10, height: 1, text: "l")
    end
    Widget::Button.new parent: form, top: 3, left: 0, width: 8, height: 1, text: "b"
  end
  s.stylesheet = sheet
  s.apply_stylesheet
  {s, forms, labels}
end

private def label_colors(labels : Array(Widget::Label))
  labels.map(&.styles.normal.fg)
end

describe "Unicode.str_width with inline SGR" do
  it "measures the text as if the SGR runs were removed" do
    cases = [
      "plain",
      "\e[1mbold\e[0m",
      "\e[38;2;1;2;3mab\e[mcd\e[1;4m",
      "\e[1m日本\e[0m語x",
      "a\e[1ḿb",      # a combining mark split from its base by a run
      "\e[1mé\e[m\tq", # non-ASCII and a control character outside runs
      "x\e[1y\e[2mz",  # an escape that opens no run, then a real one
      "tail\e[",       # truncated run
      "\e\e[1mq",      # a bare escape before a run
      "\e[1m",         # nothing but a run
    ]
    cases.each do |text|
      stripped = text.gsub(Crysterm::SGR::REGEX, "")
      Crysterm::Unicode.str_width(text, true).should eq(Crysterm::Unicode.display_width(stripped)), text.inspect
      Crysterm::Unicode.str_width(text, false).should eq(stripped.size), text.inspect
    end
  end
end

describe "CSS::Stylesheet.parse over non-ASCII text" do
  it "splits rules, blocks and declarations at the same places as in ASCII text" do
    css = <<-CSS
      /* é */ A::indicator { glyph: "▶"; color: red }
      B[data-x="é;{}"] , C { content: "→;}" ; border: 1; }
      @media (min-width: 10) { D { glyph: "✓" } E { color: blue; } }
      @keyframes pulse { from { color: red; } 50% { glyph: "●"; } to { color: blue } }
      F { G { glyph: "é" } color: green }
      CSS
    sheet = Crysterm::CSS::Stylesheet.parse css
    ascii = Crysterm::CSS::Stylesheet.parse css.gsub("▶", ">").gsub("→", "-").gsub("✓", "v").gsub("●", "o").gsub("é", "e")
    sheet.warnings.should be_empty
    sheet.rules.size.should eq ascii.rules.size
    sheet.rules.map(&.declarations.keys).should eq ascii.rules.map(&.declarations.keys)
    values = sheet.rules.flat_map(&.declarations.values)
    values.should contain "\"▶\""
    values.should contain "\"→;}\""
    values.should contain "\"✓\""
    values.should contain "\"é\""
    sheet.keyframes["pulse"].size.should eq 1
    sheet.keyframes["pulse"][0][1].map(&.[0]).should eq [0.0, 0.5, 1.0]
    sheet.keyframes["pulse"][0][1][1][1]["glyph"].should eq "\"●\""
  end

  it "parses a large sheet holding one non-ASCII character in time linear in its size" do
    css = String.build do |io|
      3000.times { |i| io << ".c" << i << " > Label[data-x=\"a;b\"] { color: #aabbcc; border: 1; }\n" }
      io << "CheckBox::indicator { glyph: \"▶\"; }\n"
    end
    started = Time.instant
    sheet = Crysterm::CSS::Stylesheet.parse css
    sheet.rules.size.should eq 3001
    # Indexing by character took tens of seconds here.
    (Time.instant - started).should be < 5.seconds
  end
end

describe "CSS cascade for a change that cannot be scoped to a subtree" do
  it "patches the cached document for a top-level widget's state flip" do
    s, forms, labels = css_tree STATE_SHEET
    control, cforms, clabels = css_tree STATE_SHEET
    patched = s.css_cascades_patched
    serialized = s.css_cascades_serialized

    forms[1].state = :hovered
    s.apply_stylesheet
    cforms[1].state = :hovered
    control.restyle
    control.apply_stylesheet
    label_colors(labels).should eq label_colors(clabels)
    labels[2].styles.normal.fg.should_not eq labels[0].styles.normal.fg
    s.css_cascades_patched.should eq patched + 1
    s.css_cascades_serialized.should eq serialized

    forms[1].state = :normal
    forms[0].add_css_class "hot"
    s.apply_stylesheet
    cforms[1].state = :normal
    cforms[0].add_css_class "hot"
    control.restyle
    control.apply_stylesheet
    label_colors(labels).should eq label_colors(clabels)
    labels[0].styles.normal.fg.should_not eq labels[2].styles.normal.fg
    s.css_cascades_serialized.should eq serialized
  ensure
    s.try &.destroy
    control.try &.destroy
  end

  it "patches the cached document under :has() rules and restyles the outer subject" do
    sheet = STATE_SHEET + "\nForm:has(.mark) { background-color: #112233; }\n"
    s, forms, labels = css_tree sheet
    control, cforms, clabels = css_tree sheet
    s.css_has_relational?.should be_true
    serialized = s.css_cascades_serialized
    before = forms[1].styles.normal.bg

    labels[3].add_css_class "mark"
    s.apply_stylesheet
    clabels[3].add_css_class "mark"
    control.restyle
    control.apply_stylesheet
    forms.map(&.styles.normal.bg).should eq cforms.map(&.styles.normal.bg)
    forms[1].styles.normal.bg.should_not eq before
    forms[0].styles.normal.bg.should eq before
    s.css_cascades_serialized.should eq serialized

    labels[3].remove_css_class "mark"
    s.apply_stylesheet
    forms[1].styles.normal.bg.should eq before
    s.css_cascades_serialized.should eq serialized
  ensure
    s.try &.destroy
    control.try &.destroy
  end
end

describe "Window#register_clickable while mouse reporting is on" do
  it "sends nothing to the terminal" do
    s = headless_screen(40, 10)
    s.enable_mouse
    s.repaint
    seq = s.tput.capture do
      5.times { |i| s.register_clickable Widget::Box.new(parent: s, top: i, left: 0, width: 6, height: 1) }
    end
    seq.should eq ""
  ensure
    s.try &.destroy
  end

  it "sends nothing while mouse reporting is off" do
    s = headless_screen(40, 10)
    s.repaint
    seq = s.tput.capture { s.register_clickable Widget::Box.new(parent: s, top: 0, left: 0, width: 6, height: 1) }
    seq.should_not contain "\e[?1000h"
  ensure
    s.try &.destroy
  end
end

describe "PlainTextEdit row decorations deep in a wrapped paragraph" do
  it "tints exactly the caret's row and a ranged selection's own columns" do
    s = headless_screen(20, 8)
    text = (0...120).join(" ") { |i| "w#{i}" }
    pe = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 8, content: text
    s.repaint
    plain = Attr.bg(s.cell_rows[0][0].attr)
    tint = Attr.pack_color(0x222244)
    mark = Attr.pack_color(0x444422)

    pos = text.size - 30
    pe.cursor_position = pos
    pe.extra_selections = [
      xsel(TextCursor.new(pe.document, pos), TextCharFormat.new(bg: 0x222244), true),
      xsel(TextCursor.new(pe.document, pos - 40, pos - 25), TextCharFormat.new(bg: 0x444422)),
    ]
    2.times do
      s.repaint
      row = pe.cursor_viewport_row
      (0...8).includes?(row).should be_true
      tinted = (0...8).select { |y| Attr.bg(s.cell_rows[y][0].attr) == tint }
      tinted.should eq [row]
      marked = 0
      8.times { |y| 20.times { |x| marked += 1 if Attr.bg(s.cell_rows[y][x].attr) == mark } }
      # A space the wrap consumed at a row's end has no cell.
      (12..15).includes?(marked).should be_true
    end

    # The caret moves up a few rows: the tint follows it.
    pe.cursor_position = pos - 45
    pe.extra_selections = [xsel(TextCursor.new(pe.document, pos - 45), TextCharFormat.new(bg: 0x222244), true)]
    s.repaint
    row = pe.cursor_viewport_row
    (0...8).select { |y| Attr.bg(s.cell_rows[y][0].attr) == tint }.should eq [row]
    Attr.bg(s.cell_rows[row == 0 ? 1 : 0][0].attr).should eq plain
  ensure
    s.try &.destroy
  end
end

describe "Damage tracking with many changed top-level widgets" do
  it "matches a full recomposite when the changed widgets stay disjoint" do
    fast = damage_window true
    full = damage_window false
    fb = tile fast
    ub = tile full
    fast.repaint
    full.repaint
    engaged = fast.damage_fast_frames

    # More changed roots than the pairwise limit, spread over the scene.
    3.times do |round|
      txt = round.even? ? "cd" : "ef"
      {fb, ub}.each { |boxes| boxes.each_with_index { |b, i| b.content = txt if i % 5 == 0 } }
      fast.repaint
      full.repaint
      assert_same_cells fast, full, "disjoint round #{round}"
    end
    fast.damage_fast_frames.should be > engaged
  ensure
    fast.try &.destroy
    full.try &.destroy
  end

  it "matches a full recomposite when changed widgets come to overlap others" do
    fast = damage_window true
    full = damage_window false
    fb = tile fast
    ub = tile full
    fast.repaint
    full.repaint

    # Many changed roots, some of which grow over an unchanged neighbour and
    # some over another changed one.
    {fb, ub}.each do |boxes|
      boxes.each_with_index do |b, i|
        next unless i % 5 == 0
        b.content = "xyz!"
        b.width = 4 if i % 40 == 0
      end
      boxes[7].left = 20
      boxes[8].left = 21
    end
    fast.repaint
    full.repaint
    assert_same_cells fast, full, "overlap"

    # And back apart.
    {fb, ub}.each do |boxes|
      boxes.each_with_index do |b, i|
        next unless i % 5 == 0
        b.content = "ab"
        b.width = 2 if i % 40 == 0
      end
      boxes[7].left = 14
      boxes[8].left = 16
    end
    fast.repaint
    full.repaint
    assert_same_cells fast, full, "apart"
  ensure
    fast.try &.destroy
    full.try &.destroy
  end
end

describe "Layout scratch state" do
  it "arranges a box whose children change between frames" do
    s = headless_screen(40, 10)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 40, height: 3, layout: Layout::HBox.new
    a = Widget::Box.new parent: box, width: 5, height: 1
    b = Widget::Box.new parent: box, height: 1
    c = Widget::Box.new parent: box, width: 7, height: 1
    s.repaint
    {a.aleft, b.aleft, c.aleft}.should eq({0, 5, 33})
    b.awidth.should eq 28

    a.hide
    s.repaint
    {b.aleft, c.aleft}.should eq({0, 33})
    b.awidth.should eq 33

    a.show
    box.remove c
    s.repaint
    {a.aleft, b.aleft}.should eq({0, 5})
    b.awidth.should eq 35
  ensure
    s.try &.destroy
  end

  it "writes a wrapping flow child's position once, so a settled layout moves nothing" do
    s = headless_screen(40, 10)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 6, layout: Layout::Wrap.new
    kids = Array.new(5) { Widget::Box.new parent: box, width: 4, height: 1 }
    s.repaint
    kids.map { |k| {k.aleft, k.atop} }.should eq [{0, 0}, {4, 0}, {0, 1}, {4, 1}, {0, 2}]

    moves = 0
    kids.each { |k| k.on(Crysterm::Event::Move) { moves += 1 } }
    2.times do
      box.update!
      s.repaint
    end
    moves.should eq 0
    kids.map { |k| {k.aleft, k.atop} }.should eq [{0, 0}, {4, 0}, {0, 1}, {4, 1}, {0, 2}]

    # A real change still moves the children after it, once each.
    kids[0].width = 8
    s.repaint
    kids.map { |k| {k.aleft, k.atop} }.should eq [{0, 0}, {0, 1}, {4, 1}, {0, 2}, {4, 2}]
    moves.should eq 4
  ensure
    s.try &.destroy
  end

  it "gravitates a masonry child in the same single write" do
    s = headless_screen(40, 10)
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 8, layout: Layout::Masonry.new
    heights = [1, 2, 1, 1]
    kids = heights.map { |h| Widget::Box.new parent: box, width: 4, height: h }
    s.repaint
    kids.map { |k| {k.aleft, k.atop} }.should eq [{0, 0}, {4, 0}, {0, 1}, {4, 2}]

    moves = 0
    kids.each { |k| k.on(Crysterm::Event::Move) { moves += 1 } }
    2.times do
      box.update!
      s.repaint
    end
    moves.should eq 0
    kids.map { |k| {k.aleft, k.atop} }.should eq [{0, 0}, {4, 0}, {0, 1}, {4, 2}]
  ensure
    s.try &.destroy
  end

  it "leaves a settled form's children unresized" do
    s = headless_screen(40, 10)
    form = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 6, layout: Layout::Form.new(label_width: 8)
    kids = Array.new(4) { Widget::Box.new parent: form, height: 1 }
    s.repaint
    kids.map { |k| {k.aleft, k.atop, k.awidth} }.should eq [{0, 0, 8}, {9, 0, 21}, {0, 1, 8}, {9, 1, 21}]

    resizes = 0
    kids.each { |k| k.on(Crysterm::Event::Resize) { resizes += 1 } }
    2.times do
      form.update!
      s.repaint
    end
    resizes.should eq 0

    # A real change still reaches the fields.
    form.width = 20
    s.repaint
    kids.map(&.awidth).should eq [8, 11, 8, 11]
    resizes.should eq 2
  ensure
    s.try &.destroy
  end
end
