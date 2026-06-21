require "../src/crysterm"

# DETACH / REATTACH: a `Screen`'s content lives independently of any window.
#
# This opens one emulator window driven by a `Screen`. A background fiber bumps a
# counter on that screen once a second. When you CLOSE the window, the `Screen`
# (and its widgets, and the counter) are NOT destroyed — they stay in memory, and
# the program immediately re-displays the SAME screen in a fresh window, with the
# counter continuing right where it left off.
#
# Press `r` to relocate to a new window yourself; press `q` (or Ctrl-Q) to quit.
#
# HOW TO RUN (needs a desktop session + a terminal emulator; honors $TERMINAL):
#   crystal examples/window-reattach.cr

include Crysterm

# `listen: true` so keys (r/q) are read immediately; the program blocks on the
# final `sleep`.
screen = Screen.open(title: "reattachable", cols: 52, rows: 12, listen: true)

box = Widget::Box.new \
  parent: screen,
  top: "center", left: "center",
  width: 46, height: 8,
  parse_tags: true,
  style: Style.new(fg: "white", bg: "blue", border: true)

count = 0
refresh = -> do
  box.set_content "{center}This {bold}Screen{/bold} survives its window.\n\n" \
                  "Counter (persists across windows): {bold}#{count}{/bold}\n\n" \
                  "Close this window — it reopens with the\nsame screen. " \
                  "Press r to relocate, q to quit.{/center}"
  screen.render if screen.connected?
end
refresh.call

spawn do
  loop do
    sleep 1.second
    count += 1
    refresh.call
  end
end

# Re-display the same screen in a brand-new window. Used both on user-close and
# on the `r` key. Guarded so a failed spawn (e.g. no emulator) exits cleanly
# instead of crashing the watcher fiber.
reattach = -> do
  begin
    Screen.open(into: screen, title: "reattached")
    refresh.call
  rescue ex
    STDERR.puts "Could not reopen window: #{ex.message}"
    exit 1
  end
end

# The window was closed by the user: the screen is already disconnected here, so
# we can safely bind it to a new window.
screen.on(Event::WindowClosed) { reattach.call }

screen.on(Event::KeyPress) do |e|
  case
  when e.char == 'q' || e.key == Tput::Key::CtrlQ
    screen.destroy
    exit 0
  when e.char == 'r'
    # Relocate on demand: drop this window and pop a fresh one with the same screen.
    screen.disconnect
    reattach.call
  end
end

sleep
