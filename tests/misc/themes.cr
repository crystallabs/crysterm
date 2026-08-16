# FEATURE: unmodified QSS (Qt) stylesheets.
#
# Crysterm's CSS engine understands Qt's QSS dialect directly, so desktop Qt
# themes style terminal apps without modification: paddings, margins, borders,
# shadows, transitions and pixel measures are translated to cells.
#
# Six *independent* headless windows run the same Qt-style scene — a menu bar,
# a completer-backed line edit, buttons and a group box — each window loaded
# with a different theme from data/css/ (`window.load_stylesheet`, or
# `--colors-stylesheet FILE` on any Crysterm program). A master window blits
# all six cell buffers into a grid, two themes per row, while one script
# drives every window at once: it opens the File menu, then filters and
# commits a completion.

require "../../src/crysterm"

include Crysterm

CELL_W = 40
CELL_H = 13
THEMES = [
  {nil, "built-in theme (no stylesheet)"},
  {"breeze-dark.qss", "breeze-dark.qss"},
  {"breeze-light.qss", "breeze-light.qss"},
  {"qdarkstyle-dark.qss", "qdarkstyle-dark.qss"},
  {"qdarkstyle-light.qss", "qdarkstyle-light.qss"},
  {"qtmodern-dark.qss", "qtmodern-dark.qss"},
]
CSS_DIR = File.expand_path "../../data/css", __DIR__

# One themed mini-app: a menu bar, a completer-backed "Lang" field, a couple
# of buttons and a group box — enough chrome for a theme to show its colors,
# borders and highlights.
record ChildApp, window : Window, menubar : Widget::MenuBar, lang : Widget::LineEdit

def build_child(theme_file : String?) : ChildApp
  w = Window.new \
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: CELL_W, height: CELL_H, alternate: false, default_quit_keys: false
  w.dock_borders = true
  w.load_stylesheet File.join(CSS_DIR, theme_file) if theme_file

  menubar = Widget::MenuBar.new parent: w, top: 0, left: 0, width: "100%", height: 1
  file = menubar.add_menu "File"
  file.add_action("New") { }
  file.add_action("Open") { }
  file.add_separator
  file.add_action("Quit") { }
  menubar.add_menu "Edit", [Action.new("Cut"), Action.new("Copy"), Action.new("Paste")]
  menubar.add_menu("Help").add_action("About") { }

  Widget::Box.new parent: w, top: 2, left: 1, width: 6, height: 1, content: "Lang:"
  lang = Widget::LineEdit.new parent: w, top: 2, left: 7, width: 14, height: 1
  Completer.new(%w[C Crystal Ruby Rust Python Perl Go]).attach lang

  Widget::Button.new parent: w, top: 2, left: 22, width: 8, height: 1,
    content: "Save", align: :center
  Widget::CheckBox.new parent: w, top: 2, left: 31, width: 9, height: 1,
    content: "Wrap", checked: true

  gb = Widget::GroupBox.new parent: w, top: 4, left: 1, right: 1, bottom: 0,
    title: "Options", checkable: true, checked: true
  Widget::Box.new parent: gb, top: 1, left: 1, width: 8, height: 1, content: "Volume:"
  Widget::Slider.new parent: gb, top: 1, left: 9, width: 24, height: 2,
    minimum: 0, maximum: 100, value: 40, text_visible: true,
    tick_position: Widget::Slider::TickPosition::Below, tick_interval: 25
  Widget::Box.new parent: gb, top: 4, left: 1, width: 8, height: 1, content: "Done:"
  Widget::ProgressBar.new parent: gb, top: 4, left: 9, width: 24, height: 1, value: 65

  ChildApp.new w, menubar, lang
end

children = THEMES.map { |(file, _label)| build_child file }

# --- Master window: captions + a blit surface --------------------------------

# Direct cell-buffer writes (the blit below) live outside the damage-tracked
# cell model, so run the master window with plain full-frame rendering.
s = Window.new title: "QSS Themes", width: 80, height: 43,
  optimization: OptimizationFlag::None

# Copies every child window's finished cell buffer (attrs, chars and grapheme
# clusters) into the master grid — six live windows composited into one.
class ThemeGrid < Widget::Box
  def initialize(@apps : Array(ChildApp), **kwargs)
    super **kwargs
  end

  def paint(*, with_children = true)
    # Establish `@lpos` via the normal box path, then overpaint with the blit.
    super

    win = window
    @apps.each_with_index do |child, i|
      # `repaint` (render + draw) is what materializes a headless window's cell
      # buffer; its escape-sequence output goes to a memory IO we discard.
      child.window.repaint
      child.window.output.as(IO::Memory).clear
      x0 = (i % 2) * CELL_W
      y0 = 2 + (i // 2) * (CELL_H + 1)
      child.window.cell_rows.each_with_index do |src_row, y|
        dst_row = win.cell_rows[y0 + y]? || break
        src_row.size.times do |x|
          src = src_row[x]
          dst = dst_row[x0 + x]? || break
          dst.attr = src.attr
          if g = src.grapheme_overlay
            dst.grapheme = g
          else
            dst.char = src.char
          end
        end
        dst_row.dirty = true
      end
    end
  end
end

Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1, parse_tags: true,
  content: "{center}{bold}Unmodified QSS themes{/bold} — one scene, six windows" \
           " · {#57c7ff-fg}--colors-stylesheet data/css/<name>.qss{/}{/center}"

ThemeGrid.new parent: s, apps: children, top: 2, left: 0, width: "100%", height: "100%-2"

# Captions render after (over) the grid — its background covers rows 15/29.
THEMES.each_with_index do |(_file, label), i|
  Widget::Box.new parent: s,
    top: 1 + (i // 2) * (CELL_H + 1), left: (i % 2) * CELL_W, width: CELL_W, height: 1,
    parse_tags: true, content: " {#8a94a6-fg}▍{/}{bold}#{label}{/bold}"
end

# --- One script, all windows -------------------------------------------------

# The same action is applied to every themed window on each beat: open the
# File menu, close it, pop the completer on the Lang field, filter, commit.
# The 2.5 s cycle divides the 5 s capture exactly, so the looping animation
# wraps seamlessly whatever the recording's start phase.
press = ->(w : Widget, char : Char, key : ::Tput::Key?) do
  w.emit Event::KeyPress, Event::KeyPress.new(char, key)
end

tick = 0
s.every(0.25.seconds) do
  case tick % 10
  when 1 then children.each &.menubar.open_menu(0)
  when 3
    children.each &.menubar.close
    children.each &.lang.focus
  when 4 then children.each { |c| press.call c.lang, '\0', ::Tput::Key::Down }
  when 5 then children.each { |c| press.call c.lang, 'C', nil }
  when 6 then children.each { |c| press.call c.lang, 'r', nil }
  when 7 then children.each { |c| press.call c.lang, '\r', ::Tput::Key::Enter }
  when 9 then children.each &.lang.value=("")
  end
  tick += 1
end

s.exec
