require "../../src/crysterm"

# Terminal-widget demo: embeds an interactive shell in a bordered box.
#
# The shell runs in a *smaller, centered* window so it's visually obvious that
# this is a terminal nested inside the Crysterm screen (rather than the app just
# being a terminal). Type in the box and use the shell as normal; press C-q to
# quit the demo (the shell itself owns every other key).
include Crysterm

screen = Screen.new

# A backdrop filling the whole screen, so the area *around* the nested terminal
# is clearly the host application and not more terminal.
Widget::Box.new \
  parent: screen,
  top: 0, left: 0, width: "100%", height: "100%",
  content: "{center}Crysterm host — nested terminal below (C-q to quit){/center}",
  parse_tags: true,
  style: Style.new(fg: "white", bg: "#202840")

term = Widget::Terminal.new(
  parent: screen,
  left: "center",
  top: "center",
  width: "70%",
  height: "60%",
  style: Style.new(fg: "white", bg: "black", border: true),
  label: " shell (C-q to quit) ",
)

term.focus

# Quit on C-q. We listen for the generic `Event::KeyPress` on the screen (and
# check `e.key`) rather than `Event::KeyPress::CtrlQ`: the per-key event
# subclasses are only emitted onto *widgets* during focus dispatch, whereas the
# screen always sees the generic event first — so this fires even though the
# focused terminal otherwise grabs every keystroke for the child shell.
screen.on(Crysterm::Event::KeyPress) do |e|
  if e.key == Tput::Key::CtrlQ
    term.kill
    screen.destroy
    exit 0
  end
end

# Re-render whenever the shell reports a new title (shown for demonstration).
term.on(Crysterm::Event::SetContent) do
  if t = term.title
    term.set_label " #{t} (C-q to quit) "
  end
end

# `exec` renders, starts the keyboard/mouse input listeners, and blocks. (Using
# `render` + `sleep` would draw the shell but never read input — so you could
# see the terminal but not type into it.)
screen.exec
