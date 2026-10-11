require "../src/crysterm"

# Cost of one widget-state flip (hover/focus) under a stylesheet, as the next
# repaint pays it through `apply_stylesheet_if_dirty`.
#
# Two scenarios over the same ~2,000-widget tree:
#   (a) the default theme only — its state rules are all subject-state
#       (`Button:hover`), precomputed per state, so a flip only patches the
#       cached document node and never cascades;
#   (b) an author sheet with ancestor-state rules (`Form:focus Button`,
#       `Box:hover Label`) plus a few dozen ordinary rules — a flip dirties the
#       cascade, which is where the per-flip time goes.
#
# Per scenario: µs and KiB per hover flip and per focus move, then the split
# of one dirty cascade into its pieces (serialize, compare, parse/patch, match
# + fold), measured by re-running the cascade's own steps.
#
# Run:  crystal run --release benchmarks/css-state-flip.cr

alias CT = Crysterm
alias CW = CT::Widgets

CT::Config.set "screen.headless", CT::Headless::Always

ROUNDS = 400

class Crysterm::Window
  def bench_apply_if_dirty : Nil
    apply_stylesheet_if_dirty
  end

  def bench_cascade_split : Hash(String, Float64)
    times = {} of String => Float64
    author = @css_stylesheet
    default = CSS.default_stylesheet
    t = Time.instant
    widget_sheets = collect_css_widget_sheets
    times["collect_widget_sheets"] = (Time.instant - t).total_microseconds
    t = Time.instant
    document = to_html
    times["to_html"] = (Time.instant - t).total_microseconds
    t = Time.instant
    same = document == @css_last_document
    times["string_compare"] = (Time.instant - t).total_microseconds
    raise "document unexpectedly unchanged" if same
    @css_last_document = document
    t = Time.instant
    scope = (@css_full || @css_dirty_roots.empty?) ? nil : css_scope_widgets
    times["scope"] = (Time.instant - t).total_microseconds
    t = Time.instant
    doc = css_parsed_document(document)
    times["parse_or_patch"] = (Time.instant - t).total_microseconds
    variables, resolved = css_var_caches(author, default, CSS.default_stylesheet_generation)
    sheets = Array(Tuple(CSS::Stylesheet, Int32, Widget?)).new
    sheets << {default, CSS::Cascade::TIER_DEFAULT, nil}
    author.try { |sheet| sheets << {sheet, CSS::Cascade::TIER_AUTHOR, nil} }
    @css_extra_stylesheets.each { |sheet| sheets << {sheet, CSS::Cascade::TIER_AUTHOR, nil} }
    widget_sheets.each { |(sheet, owner)| sheets << {sheet, CSS::Cascade::TIER_WIDGET, owner} }
    t = Time.instant
    CSS::Cascade.apply_sheets sheets, self, doc, scope, variables, resolved
    times["apply_sheets"] = (Time.instant - t).total_microseconds
    @css_widgets_styled = true
    clear_css_dirty
    times
  end
end

# ~2,000 widgets: 8 forms × 6 boxes × (a label, 4 buttons, a line edit, and a
# nested box with 2 labels and 1 button) — 8 × 6 × (1 + 4 + 1 + 1 + 3) = 480
# leaves plus containers, repeated in 4 top-level groups.
def build_tree(s : CT::Window) : Tuple(Array(CT::Widget), Array(CW::Button), Array(CW::Label))
  all = [] of CT::Widget
  buttons = [] of CW::Button
  labels = [] of CW::Label
  4.times do |g|
    group = CW::Box.new parent: s, top: g * 20, left: 0, width: "100%", height: 20
    all << group
    8.times do |f|
      form = CW::Form.new parent: group, top: 0, left: f * 30, width: 30, height: 20
      all << form
      6.times do |b|
        box = CW::Box.new parent: form, top: b * 3, left: 0, width: 30, height: 3
        all << box
        lbl = CW::Label.new parent: box, top: 0, left: 0, width: 10, height: 1, text: "label"
        all << lbl
        labels << lbl
        4.times do |k|
          btn = CW::Button.new parent: box, top: 1, left: k * 7, width: 6, height: 1, text: "b#{k}"
          all << btn
          buttons << btn
        end
        le = CW::LineEdit.new parent: box, top: 2, left: 0, width: 20, height: 1
        all << le
        inner = CW::Box.new parent: box, top: 2, left: 20, width: 10, height: 1
        all << inner
        2.times do |j|
          l2 = CW::Label.new parent: inner, top: 0, left: j * 3, width: 3, height: 1, text: "x"
          all << l2
          labels << l2
        end
        btn2 = CW::Button.new parent: inner, top: 0, left: 6, width: 4, height: 1, text: "ok"
        all << btn2
        buttons << btn2
      end
    end
  end
  {all, buttons, labels}
end

ORDINARY_RULES = String.build do |io|
  io << "Button { background-color: #333344; color: #ddddee; }\n"
  io << "Label { color: #aaaaaa; }\n"
  io << "LineEdit { background-color: #222233; }\n"
  io << "Form { border: 1; }\n"
  io << "Box > Label { font-weight: bold; }\n"
  30.times do |i|
    io << ".cls#{i} { color: #0000#{(i * 7 % 256).to_s(16).rjust(2, '0')}; }\n"
  end
end

ANCESTOR_RULES = ORDINARY_RULES + <<-CSS
  Form:focus Button { background-color: #ff0000; }
  Box:hover Label { color: #0000ff; }
  CSS

def measure(label : String, n : Int32, &block) : Nil
  block.call # warm
  GC.collect
  b0 = GC.stats.total_bytes
  t0 = Time.instant
  n.times { block.call }
  dt = (Time.instant - t0).total_microseconds / n
  db = (GC.stats.total_bytes - b0) / n / 1024.0
  printf "  %-34s %9.1f µs/op  %8.1f KiB/op\n", label, dt, db
end

def scenario(name : String, sheet : String?) : Nil
  s = CT::Window.new input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 240, height: 80, optimization: CT::OptimizationFlag::None
  all, buttons, labels = build_tree s
  s.stylesheet = sheet if sheet
  s.repaint
  puts "\n#{name}: #{all.size} widgets, dynamic_state=#{s.css_dynamic_state?} relational=#{s.css_has_relational?}"

  # The deepest widgets: a nested-box button and label.
  btn = buttons[-1]
  lbl = labels[-1]
  inner = lbl.parent.as(CT::Widget)
  other = buttons[0]

  measure("hover flip (label)", ROUNDS) do
    lbl.state = :hovered
    s.bench_apply_if_dirty
    lbl.state = :normal
    s.bench_apply_if_dirty
  end
  measure("hover flip (nested-box parent)", ROUNDS) do
    inner.state = :hovered
    s.bench_apply_if_dirty
    inner.state = :normal
    s.bench_apply_if_dirty
  end
  measure("focus move (button <-> button)", ROUNDS) do
    btn.focus
    s.bench_apply_if_dirty
    other.focus
    s.bench_apply_if_dirty
  end

  # Split of one dirty cascade (only meaningful when the flip dirties it).
  if s.css_dynamic_state?
    btn.state = :normal
    s.bench_apply_if_dirty
    acc = Hash(String, Float64).new(0.0)
    20.times do |i|
      btn.state = i.even? ? :hovered : :normal
      s.bench_cascade_split.each { |k, v| acc[k] += v }
    end
    puts "  one dirty cascade, pieces (µs, mean of 20):"
    acc.each { |k, v| printf "    %-24s %9.1f\n", k, v / 20 }
  end
end

scenario "(a) default theme only", nil
scenario "(b) author sheet with ancestor-state rules", ANCESTOR_RULES
