# FEATURE: direct (inline) mode — a full widget app on the command line.
#
# `Window.new inline: true` runs the complete widget stack — focus, input,
# popups, styling, damage-tracked rendering — *without* taking over the
# terminal: no alternate screen, no full-screen scroll region. The app renders
# at the shell cursor and everything above stays in the scrollback, exactly
# like `fzf` or a shell's own completion menu. `auto_grow: true` (with
# `max_height:`) even starts one row tall and grows with content.
#
# Here a type-ahead `Completer` attached to a `LineEdit` plays a shell
# command line: it types a prefix, the completion list pops up under the
# prompt, filters as it types, and Enter commits. The demo drives itself in a
# loop; it is equally usable interactively (type, ↓ opens the list, Tab/Enter
# accepts, Ctrl-Q quits).
#
# See also `Crysterm::Direct` (tests/misc/direct.cr) for the widget-less
# print-styled-text-and-exit flavor of direct mode.

require "../../../src/crysterm"

include Crysterm

COMMANDS = %w[bench build clean deploy docs format install lint publish release run spec update]

# The scrollback line the committed command "produces" each cycle.
DONE = "{#8a94a6-fg}❯ deploy\n{/}{#98c379-fg}  ✓ deploy: 3 targets updated{/}"

# An inline window: 12 rows at the shell cursor, normal buffer, scrollback
# above it intact.
s = Window.new title: "completer", inline: true, height: 12

history = Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 2,
  parse_tags: true, content: DONE

Widget::Box.new parent: s, top: 2, left: 0, width: 2, height: 1,
  parse_tags: true, content: "{#57c7ff-fg}❯{/}"
cmd = Widget::LineEdit.new parent: s, top: 2, left: 2, width: 32, height: 1
Completer.new(COMMANDS).attach cmd
cmd.focus

Widget::Box.new parent: s, bottom: 0, left: 0, width: "100%", height: 1,
  parse_tags: true,
  content: "{#8a94a6-fg}type to filter · ↓ opens the list · Tab/Enter accepts · Ctrl-Q quits{/}"

# --- Self-driving script (also fine to type over interactively) --------------

# The 2.5 s cycle divides the 5 s capture exactly, and each cycle ends back in
# the starting state, so the looping animation wraps seamlessly whatever the
# recording's start phase.
press = ->(char : Char, key : ::Tput::Key?) do
  cmd.emit Event::KeyPress, Event::KeyPress.new(char, key)
end

tick = 0
s.every(0.25.seconds) do
  case tick % 10
  when 1 then press.call 'd', nil
  when 2 then press.call 'e', nil
  when 4 then press.call '\0', ::Tput::Key::Down # highlight the top match
  when 6 then press.call '\r', ::Tput::Key::Enter
  when 8 then history.content = "{#8a94a6-fg}❯ #{cmd.value}{/}" # "running"
  when 9
    history.content = DONE
    cmd.value = ""
  end
  tick += 1
end

s.exec
