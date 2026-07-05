# Example: Crysterm::Widget::Terminal
#
# Minimal, self-contained example of a single Terminal.
# Run it:     crystal run tests/widget/terminal/terminal.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Terminal" do |screen|
  screen.stylesheet = "Terminal { border: solid; }"
  # A Terminal spawns a shell (`$SHELL`) in a PTY on first render and draws its
  # live grid — no `content:` is used, the emulator overwrites the inner area.
  # `.focus` is what makes it usable: keystrokes are only forwarded to the child
  # while focused (and the cursor is only drawn then). Without it you'd see a
  # running-but-untypable shell.
  term = Crysterm::Widget::Terminal.new \
    parent: screen, top: 0, left: 0, width: "100%", height: "100%"
  term.focus
end
