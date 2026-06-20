# FEATURE: dual-source unified mouse handling.
#
# Crysterm normalizes mouse input from two different sources — xterm SGR/X10
# escape sequences AND the Linux console `gpm` daemon — into a single
# `Event::Mouse`. Application code never needs to know where an event came from.
#
# Because a recorded GIF has no real pointer, this demo *synthesizes* normalized
# events from both sources (`source: :xterm` and `source: :gpm`) and feeds them
# through the very same `dispatch_mouse` path the real inputs use. The log shows
# both sources handled identically; the click target reacts to synthetic clicks.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Mouse"
s.show_fps = nil

log = Widget::Box.new \
  parent: s,
  top: 0, left: 0, width: "100%", height: 9,
  content: "Unified mouse events (xterm + gpm) -> one Event::Mouse:",
  scrollable: true,
  style: Style.new(fg: "white", bg: "black", border: true)

target = Widget::Box.new \
  parent: s,
  top: 10, left: 2, width: 30, height: 4,
  content: "{center}Click target{/center}",
  parse_tags: true,
  style: Style.new(fg: "black", bg: "green", border: true)

# A marker that follows the synthetic pointer.
marker = Widget::Box.new \
  parent: s, top: 10, left: 40, width: 3, height: 1,
  content: "<>", style: Style.new(fg: "black", bg: "yellow")

lines = [] of String
add = ->(text : String) {
  lines << text
  lines.shift if lines.size > (log.aheight - 2)
  log.content = "Unified mouse events (xterm + gpm) -> one Event::Mouse:\n" + lines.join("\n")
}

green = true
s.on(Event::Mouse) do |e|
  tag = e.mouse.source == :gpm ? "{cyan-fg}[gpm]  {/}" : "{green-fg}[xterm]{/}"
  add.call "#{tag} #{e.action.to_s.ljust(9)} #{e.button.to_s.ljust(6)} @ #{e.x},#{e.y}"
end

target.on(Event::Click) do
  green = !green
  target.style.bg = green ? "green" : "red"
end

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

# Drive synthetic events, alternating the two sources.
spawn do
  t = 0.0
  loop do
    src = (t.to_i % 2 == 0) ? :xterm : :gpm
    x = (4 + (Math.sin(t) * 0.5 + 0.5) * (s.awidth - 8)).to_i
    y = (10 + (Math.sin(t * 0.7) * 0.5 + 0.5) * 3).to_i

    marker.clear_last_rendered_position
    marker.left = x
    marker.top = y

    move = ::Tput::Mouse::Event.new(
      action: ::Tput::Mouse::Action::Move, button: ::Tput::Mouse::Button::None,
      x: x, y: y, source: src)
    s.dispatch_mouse move

    # Occasionally click the target.
    if (t * 10).to_i % 13 == 0
      cx, cy = 6, 11
      s.dispatch_mouse ::Tput::Mouse::Event.new(
        action: ::Tput::Mouse::Action::Down, button: ::Tput::Mouse::Button::Left,
        x: cx, y: cy, source: src)
      s.dispatch_mouse ::Tput::Mouse::Event.new(
        action: ::Tput::Mouse::Action::Up, button: ::Tput::Mouse::Button::Left,
        x: cx, y: cy, source: src)
    end

    t += 0.25
    s.render
    sleep 0.12.seconds
  end
end

s.exec
