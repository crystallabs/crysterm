require "../../src/crysterm"

# Port of blessed's `example/ansi-viewer`, reworked into a three-pane image
# viewer driven by `Widget::Media`.
#
#   +----------+--------------------------------+
#   | Image    |                                |
#   +----------|                                |
#   | Fit ···  |            viewer              |
#   +----------|        (Widget::Media)         |
#   | Render   |                                |
#   | Method   |                                |
#   +----------+--------------------------------+
#
# A 25-cell sidebar holds:
#   * Image         — every file in the repo's `data/image/`
#   * Fit           — a one-line selector: 1:1 / stretch / fit (default) / zoom
#   * Render Method — a Tree of the Media output backends, Glyph/Ansi expanded
#                     into their sub-modes; backends the terminal/host can't drive
#                     are dimmed "(n/a)" and ignored on selection.
#
# The viewer fills the rest and is a `Widget::Media`, so it shows any format the
# Media pipeline can decode — including `.ans` ANSI art, which `Media.decode`
# rasterizes to a bitmap (an input decoder, peer to PNGGIF) and any output
# backend then renders.
#
# Keys:  arrows/j/k select   Right/Left expand/collapse   Tab switch pane   q quit

include Crysterm
alias M = Widget::Media

IMAGE_DIR = File.join(__DIR__, "..", "..", "data", "image")

files = Dir.children(IMAGE_DIR).select { |f| File.file?(File.join(IMAGE_DIR, f)) }.sort
paths = files.map { |f| File.expand_path(File.join(IMAGE_DIR, f)) }
start_idx = files.index { |f| !f.ends_with?(".ans") } || 0

# `force_unicode` so the Glyph backend's rich mosaics (quadrant/sextant/octant,
# braille) render as real Unicode glyphs instead of Crysterm's ACS "?" fallback
# on terminals not auto-detected as Unicode-capable. Octants are Unicode 16
# (2024), so they still need an up-to-date terminal font.
screen = Window.new title: "viewer.cr", force_unicode: true
screen.enable_mouse

root = Widget::Box.new parent: screen, top: 0, left: 0, width: "100%", height: "100%",
  layout: Layout::Border.new, overflow: :ignore

# Left column: fixed 25 cells. Children are positioned by hand so the Fit row is
# exactly one line, with the two lists taking the halves above and below it.
sidebar = Widget::Box.new parent: root, width: 25,
  layout_hint: Layout::Border::Hint.new(:left)

chooser = Widget::List.new parent: sidebar, items: files, mouse: true, vi: true,
  scrollbar: true, top: 0, left: 0, width: "100%", height: "50%-1",
  label: " Image ", style: Style.new(border: true)

# The Fit selector: a single line — the label "Fit" followed by the four options
# laid out in a row, the active one inverted. (A ListBar pads each item too wide
# to fit four options plus a label in 25 cells, so this is a compact custom row.)
FITS = [{"1:1", M::Fit::None}, {"stretch", M::Fit::Stretch}, {"fit", M::Fit::Contain}, {"zoom", M::Fit::Cover}]
fit_names = FITS.map { |(n, _)| n }
fitrow = Widget::Box.new parent: sidebar, top: "50%-1", left: 0, width: "100%", height: 1,
  parse_tags: true, input: true

backends = Widget::Tree.new parent: sidebar, mouse: true, vi: true,
  top: "50%", left: 0, width: "100%", height: "50%",
  label: " Render Method ", style: Style.new(border: true)

viewer_box = Widget::Box.new parent: root, layout_hint: Layout::Border::Hint.new(:center),
  style: Style.new(border: true)

# --- viewer state ----------------------------------------------------------
current_path = paths[start_idx]? || ""
current_type = nil.as(M::Type?)        # nil = Auto
current_mode = nil.as(M::Glyph::Mode?) # Glyph sub-mode
current_colors = nil.as(M::Ansi::ColorMode?)
current_fit = M::Fit::Contain # "fit" default
media = nil.as(M::Base?)

show = -> {
  media.try &.destroy
  t = current_type
  cm = current_mode
  cc = current_colors
  # Backend-specific options (Glyph's `mode`, Ansi's `colors`) can't pass through
  # the generic `Media.new` factory, so construct those concrete classes directly.
  m =
    if t.try(&.glyph?)
      M::Glyph.new(parent: viewer_box, file: current_path, width: "100%", height: "100%",
        fit: current_fit, mode: cm.nil? ? M::Glyph::Mode::Half : cm)
    elsif t.try(&.ansi?)
      M::Ansi.new(parent: viewer_box, file: current_path, width: "100%", height: "100%",
        fit: current_fit, color_mode: cc.nil? ? M::Ansi::ColorMode::TrueColor : cc)
    else
      M.new(parent: viewer_box, type: t, file: current_path, width: "100%", height: "100%",
        fit: current_fit)
    end
  media = m
  viewer_box.set_label " #{File.basename current_path} — #{(t.try(&.to_s) || "Auto")} "
  screen.render
}

# --- Image chooser ---------------------------------------------------------
chooser.on(Event::ItemSelected) do |e|
  if p = paths[e.index]?
    current_path = p
    show.call
  end
end

# --- Fit selector ----------------------------------------------------------
fit_idx = FITS.index! { |(_, f)| f == M::Fit::Contain } # default highlight: "fit"
# Click ranges for each option within the row ("Fit " prefix is 4 cells wide).
fit_ranges = [] of Tuple(Int32, Int32, Int32)
fpos = 4
fit_names.each_with_index do |n, i|
  fit_ranges << {fpos, fpos + n.size - 1, i}
  fpos += n.size + 1
end

render_fit = -> {
  parts = fit_names.map_with_index { |n, i| i == fit_idx ? "{inverse}#{n}{/inverse}" : n }
  fitrow.set_content "Fit " + parts.join(' ')
}

set_fit = ->(i : Int32) {
  return if i < 0 || i >= FITS.size || i == fit_idx
  fit_idx = i
  current_fit = FITS[i][1]
  render_fit.call
  show.call
}

fitrow.on(Event::Mouse) do |e|
  next unless e.action.up? # act on the click release
  rx = e.x - (fitrow.aleft || 0)
  if hit = fit_ranges.find { |(a, b, _)| a <= rx <= b }
    set_fit.call(hit[2])
  end
end

fitrow.on(Event::KeyPress) do |e|
  case e.key
  when Tput::Key::Left  then set_fit.call(fit_idx - 1)
  when Tput::Key::Right then set_fit.call(fit_idx + 1)
  end
end

render_fit.call

# --- Render Method tree ----------------------------------------------------
glyph_subs = M::Glyph::Mode.values.map { |mode| {mode.to_s, "Glyph/#{mode}"} }
ansi_subs = M::Ansi::ColorMode.values.map { |c| {c.to_s, "Ansi/#{c}"} }
backend_defs = [
  {M::Type::Ansi, ansi_subs},
  {M::Type::Glyph, glyph_subs},
  {M::Type::Sixel, [] of Tuple(String, String)},
  {M::Type::Kitty, [] of Tuple(String, String)},
  {M::Type::Iterm, [] of Tuple(String, String)},
  {M::Type::Overlay, [] of Tuple(String, String)},
  {M::Type::Ueberzug, [] of Tuple(String, String)},
  {M::Type::Regis, [] of Tuple(String, String)},
  {M::Type::Tek, [] of Tuple(String, String)},
]

# Mark a node label when its backend can't render here. Plain text — color tags
# would lengthen the row past the narrow pane, wrapping it and throwing off the
# click→row mapping.
label_for = ->(text : String, avail : Bool) { avail ? text : "#{text} (n/a)" }

backend_defs.each do |(type, subs)|
  avail = M.available?(type, screen.tput)
  node = backends.add(label_for.call(type.to_s, avail), type.to_s)
  subs.each { |(label, data)| node.add(label_for.call(label, avail), data) }
end
# Leave collapsed: top-level backends (with their "(n/a)" markers) stay visible;
# expand Ansi/Glyph (Right/Enter) to reach their sub-modes.

backends.on(Event::ItemSelected) do |_e|
  node = backends.selected_node
  next unless node
  data = node.data
  next unless data
  base, _, sub = data.partition('/')
  type = M::Type.parse?(base)
  next unless type
  next unless M.available?(type, screen.tput) # "(n/a)" backends are inert

  current_type = type
  current_mode = type.glyph? && !sub.empty? ? M::Glyph::Mode.parse?(sub) : nil
  current_colors = type.ansi? && !sub.empty? ? M::Ansi::ColorMode.parse?(sub) : nil
  show.call
end

# --- keys ------------------------------------------------------------------
screen.on(Event::KeyPress) do |e|
  if e.char == 'q'
    exit 0
  elsif e.key == Tput::Key::Tab
    screen.focus_next
    screen.render
  end
end

chooser.focus
chooser.select_index(start_idx)

# Paint one frame so the layout sizes the panes, then build the first image.
screen._render
show.call unless current_path.empty?

screen.exec
