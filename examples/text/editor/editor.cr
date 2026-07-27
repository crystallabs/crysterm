# FEATURE: full Unicode — a working text editor with icon chrome.
#
# Crysterm is Unicode-native end to end: grapheme clusters (ZWJ emoji,
# combining marks), wide CJK cells, ambiguous-width resolution probed from the
# terminal, and glyph chrome that auto-upgrades on modern-font terminals. This
# is a usable little editor — menu bar, tool bar with Unicode icon buttons,
# status bar with live Ln/Col — built on `TextEdit`: full undo/redo stack
# (C-z / M-z), Emacs kill-ring (C-k / C-y), readline motion, selections and
# mouse support (wheel scrolling, click-to-position, menu clicks).
#
# The demo drives itself: it types Unicode text, opens the File menu with a
# synthetic mouse click, and wheel-scrolls the document. Run it interactively
# and it's simply an editor (Ctrl-Q quits).

require "../../../src/crysterm"

include Crysterm

SAMPLE = <<-TEXT
Crysterm speaks Unicode natively.

Scripts    — English, Ćirilica, Ελληνικά, 中文, 日本語, 한국어, हिन्दी
Emoji      — 🚀 🌍 🎨 ✅ ❤️ and ZWJ families: 👨‍👩‍👧‍👦
Combining  — e + ◌́ = é,  a + ◌̈ = ä,  ω + ◌̃ = ω̃
Wide cells — ｆｕｌｌｗｉｄｔｈ next to halfwidth
Symbols    — ┌─┬─┐ ╭─╮ ▲ ► ◆ ● · § ¶ † ∞ ≠ ⊕ ⌘

Every line above lays out on the exact cell grid the terminal uses:
grapheme clusters stay whole, wide glyphs take two cells, combining
marks take none — and the same rules drive the cursor, selections,
kill-ring and undo below.

Try it: type anywhere; C-z / M-z undo and redo; C-k kills to end of
line and C-y yanks it back (the kill-ring is shared process-wide);
C-Left / C-Right jump words; Shift+arrows select; the wheel scrolls.

  “Ćevapčići & smörgåsbord — 東京で書く, писати у Београду,
   γράφοντας στην Αθήνα — all in one buffer.”

The status bar below tracks Ln/Col live, the toolbar buttons are
plain Unicode glyphs, and everything you see is themable with CSS.
TEXT

s = Window.new title: "Editor"

win = Widget::MainWindow.new parent: s, top: 0, left: 0, width: "100%", height: "100%"

status = Widget::StatusBar.new
win.status_bar = status
pos_i = status.add_permanent "⌖ Ln 1, Col 1"
status.add_permanent "🌐 UTF-8"
mod_i = status.add_permanent "✔ saved"

ed = Widget::TextEdit.new input_on_focus: true
win.central_widget = ed

# --- Menus -------------------------------------------------------------------

menubar = Widget::MenuBar.new
win.menu_bar = menubar

msg = ->(t : String) { status.show_message " #{t}"; s.render }

file = menubar.add_menu "File"
file.add_action("📄 New") { ed.text = ""; msg.call "new buffer" }
file.add_action("📂 Open") { ed.text = SAMPLE; msg.call "opened sample.txt" }
file.add_action("💾 Save") { status.set_permanent mod_i, "✔ saved"; msg.call "saved sample.txt" }
file.add_separator
file.add_action("Quit") { s.destroy; exit }

edit = menubar.add_menu "Edit"
edit.add_action("↶ Undo") { ed.undo; msg.call "undo" }
edit.add_action("↷ Redo") { ed.redo; msg.call "redo" }

menubar.add_menu("Help").add_action("About") { msg.call "Crysterm editor — full Unicode" }

# --- Tool bar: Unicode icon buttons ------------------------------------------

toolbar = Widget::ToolBar.new
win.add_tool_bar toolbar
toolbar.add_button("📄") { ed.text = ""; msg.call "new buffer" }
toolbar.add_button("📂") { ed.text = SAMPLE; msg.call "opened sample.txt" }
toolbar.add_button("💾") { status.set_permanent mod_i, "✔ saved"; msg.call "saved sample.txt" }
toolbar.add_separator
toolbar.add_button("↶") { ed.undo; msg.call "undo" }
toolbar.add_button("↷") { ed.redo; msg.call "redo" }

# --- Live Ln/Col + modified flag ---------------------------------------------

ed.text = SAMPLE
ed.focus

update_pos = -> do
  cur = ed.text_cursor
  status.set_permanent pos_i, "⌖ Ln #{cur.block_number + 1}, Col #{cur.column_number + 1}"
end

ed.on(Event::TextChanged) do
  status.set_permanent mod_i, "✎ modified"
  update_pos.call
end
update_pos.call

# --- Self-driving script: typing, a mouse click on a menu, wheel scrolling ---

type = ->(text : String) do
  text.each_char { |ch| ed.emit Event::KeyPress, Event::KeyPress.new(ch, nil) }
end
mouse = ->(action : ::Tput::Mouse::Action, x : Int32, y : Int32) do
  s.dispatch_mouse ::Tput::Mouse::Event.new(action, ::Tput::Mouse::Button::Left, x, y)
end

tick = 0
s.every(0.25.seconds) do
  case tick % 20
  when 1 then type.call "❯ edited with 🎉 — "
  when 3 then type.call "Здраво, 世界! "
  when 6 # click the File menu open, like a real pointer would
    mouse.call ::Tput::Mouse::Action::Down, 2, 0
    mouse.call ::Tput::Mouse::Action::Up, 2, 0
  when 10         then menubar.close
  when 11         then ed.focus
  when 12, 13, 14 then mouse.call ::Tput::Mouse::Action::WheelUp, 40, 10
  when 16, 17     then mouse.call ::Tput::Mouse::Action::WheelDown, 40, 10
  when 19         then ed.undo; ed.undo
  end
  tick += 1
end

s.exec
