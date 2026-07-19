require "../../src/crysterm"

# Port of Blessed's test/widget-termswitch.js
#
# Blessed switches the live terminal type at runtime (`screen.terminal = 'vt100'`)
# and re-renders. Crysterm loads terminfo once per `Screen`, so the equivalent is
# `Screen#switch_terminal`: builds a new screen on the requested terminal,
# reparents existing widgets onto it, destroys the old screen, returns the new one.
# This demo shows widgets on the default terminal for ~1s, then switches to `vt100`.
module Crysterm
  lorem = (1..40).map { |i| "Line #{i}: Lorem ipsum dolor sit amet, consectetur adipiscing elit." }.join("\n")

  quit = ->(scr : Window, e : Event::KeyPress) do
    if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
      scr.destroy
      exit
    end
  end

  # --- Initial screen, on the default terminal. ---
  s = Window.new optimization: OptimizationFlag::SmartCSR, always_propagated_keys: [::Tput::Key::CtrlQ]

  btext = Widget::Box.new(
    parent: s,
    left: "center", top: "center",
    width: "80%", height: "80%",
    style: Style.new(bg: "green", border: BorderType::Solid),
    content: "Terminal: default — switching to vt100 in 1s…",
  )

  text = Widget::ScrollableText.new(
    parent: s,
    content: lorem,
    style: Style.new(border: BorderType::Solid),
    left: "center", top: "center",
    draggable: true,
    width: "50%", height: "50%",
    keys: true, vi_keys: true,
  )

  text.focus
  s.on(Event::KeyPress) { |e| quit.call s, e }
  s.render

  # Show the default terminal briefly, then switch — one call handles teardown,
  # new screen, and reparenting.
  sleep 1.seconds
  s = s.switch_terminal "vt100"

  btext.set_content "Terminal: vt100 (widgets reparented onto the new screen)"
  text.focus
  s.on(Event::KeyPress) { |e| quit.call s, e }
  s.render
  s.exec
end
