require "../../src/crysterm"

# Port of Blessed's test/widget-termswitch.js
#
# Blessed switches the *live* terminal type at runtime (`screen.terminal =
# 'vt100'`) and re-renders. Crysterm loads terminfo once per `Screen`, so the
# equivalent is a single `Screen#switch_terminal` call: it builds a new screen on
# the requested terminal, reparents the existing widgets onto it, destroys the
# old screen and returns the new one. This demo shows the widgets on the default
# terminal for ~1s, then switches to `vt100`.
module Crysterm
  lorem = (1..40).map { |i| "Line #{i}: Lorem ipsum dolor sit amet, consectetur adipiscing elit." }.join("\n")

  quit = ->(scr : Screen, e : Event::KeyPress) do
    if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
      scr.destroy
      exit
    end
  end

  # --- Initial screen, on the default terminal. ---
  s = Window.new optimization: OptimizationFlag::SmartCSR, always_propagate: [::Tput::Key::CtrlQ]

  btext = Widget::Box.new(
    parent: s,
    left: "center", top: "center",
    width: "80%", height: "80%",
    style: Style.new(bg: "green", border: BorderType::Line),
    content: "Terminal: default — switching to vt100 in 1s…",
  )

  text = Widget::ScrollableText.new(
    parent: s,
    content: lorem,
    style: Style.new(border: BorderType::Line),
    left: "center", top: "center",
    draggable: true,
    width: "50%", height: "50%",
    keys: true, vi: true,
  )

  text.focus
  s.on(Event::KeyPress) { |e| quit.call s, e }
  s.render

  # Show the default terminal briefly, then switch — one call does the teardown,
  # the new-terminal screen, and reparenting the widgets onto it.
  sleep 1.seconds
  s = s.switch_terminal "vt100"

  btext.set_content "Terminal: vt100 (widgets reparented onto the new screen)"
  text.focus
  s.on(Event::KeyPress) { |e| quit.call s, e }
  s.render
  s.exec
end
