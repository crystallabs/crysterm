# FEATURE: event-driven architecture (EventHandler pub/sub).
#
# Everything in Crysterm communicates through typed events emitted on objects
# you can subscribe to with `obj.on(Event::Type) { ... }`. The same event can
# have many independent subscribers. Here a driver fiber fires events and
# several handlers react — one log, one counter — all from the same stream.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Events"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Typed events with multiple subscribers{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#302840")

log = Widget::Log.new \
  parent: s, top: 1, left: 0, width: 54, height: 14,
  label: " event log ", scrollback: 100,
  style: Style.new(fg: "white", bg: "black", border: true)

counter = Widget::Box.new \
  parent: s, top: 1, left: 55, width: 23, height: 6,
  content: "{center}keys seen{/center}\n\n{center}0{/center}", parse_tags: true,
  style: Style.new(fg: "yellow", bg: "#101010", border: true)

checkbox = Widget::Checkbox.new \
  parent: s, top: 8, left: 57, content: "subscribed flag"

# Two independent subscribers to the SAME event type.
key_count = 0
s.on(Event::KeyPress) do |e|
  log.add "Event::KeyPress  char=#{e.char.inspect}"
end
s.on(Event::KeyPress) do |e|
  key_count += 1
  counter.content = "{center}keys seen{/center}\n\n{center}#{key_count}{/center}"
end

# Subscribers to checkbox state events.
checkbox.on(Event::Check) { log.add "Event::Check     (checkbox on)" }
checkbox.on(Event::UnCheck) { log.add "Event::UnCheck   (checkbox off)" }

# Driver: emit a stream of events through the system.
demo_keys = "crysterm".chars
i = 0
s.every(0.3.seconds) do
  s.emit Event::KeyPress.new demo_keys[i % demo_keys.size]
  checkbox.toggle if i % 4 == 0
  i += 1
end

s.exec
