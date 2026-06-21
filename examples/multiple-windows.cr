require "../src/crysterm"

# Opening and driving MULTIPLE terminal emulator WINDOWS from one program.
#
# Unlike `examples/multiple-terminals.cr` (which attaches to terminals you opened
# and freed by hand), this program *spawns* the emulator windows itself: it
# launches your terminal emulator (auto-detected; honors $TERMINAL), waits for an
# in-window helper to report the new window's TTY, and binds a Crysterm `Screen`
# to each — all via `Screen.open` / `Screen.run`. No manual `tty` / `exec sleep
# infinity` dance required.
#
# HOW TO RUN
#   crystal examples/multiple-windows.cr
#
# Three new emulator windows pop up, each rendering its own independent screen.
# Press `q` (or Ctrl-Q) in any window — or just close a window — to tear things
# down; the program exits once the last window is gone.
#
# Requires a desktop session with a terminal emulator installed (xterm, kitty,
# alacritty, foot, konsole, st, wezterm, or gnome-terminal). Set $TERMINAL to
# force a particular one.

include Crysterm

Screen.run(windows: 3, cols: 60, rows: 18) do |screen, i|
  Widget::Box.new \
    parent: screen,
    top: "center",
    left: "center",
    width: 44,
    height: 7,
    content: "{center}This is {bold}window ##{i + 1}{/bold}.\n\n" \
             "Spawned and driven by one program.\n\n" \
             "Press close to close window, q to quit app.{/center}",
    parse_tags: true,
    style: Style.new(fg: "white", bg: "blue", border: true)

  # A per-window heartbeat so you can see each window updating independently.
  box = screen.children.first.as(Widget::Box)
  spawn do
    tick = 0
    loop do
      sleep 1.second
      break unless screen.connected?
      tick += 1
      box.set_label " window ##{i + 1} — tick #{tick} "
      screen.render
    end
  end
end
