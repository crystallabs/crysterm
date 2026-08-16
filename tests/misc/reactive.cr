# FEATURE: Reactive programming.
#
# A `Reactive::Property` is an observable value cell. Widgets subscribe to it
# with `Reactive.bind` (explicit dependencies) or `Reactive.effect`
# (dependencies auto-tracked from what the block reads), and
# `Reactive.computed` derives new signals from existing ones.
#
# Here ONE signal drives everything: a timer assigns `level.value` along a
# sine wave, and the progress bar, the seven-segment readout, the meter and
# the computed status label all update themselves. Nothing else ever touches
# the widgets.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Reactive"

# The single piece of application state. (Starts mid-wave so even the very
# first frame shows the widgets tracking a live value.)
level = Reactive::Property.new 62

# Signals derived from `level`, recomputed only when it changes.
status = Reactive.computed do
  case level.value
  when 0...25  then "{#e06c75-fg}▁ LOW — spinning up{/}"
  when 25...50 then "{#e5c07b-fg}▃ MEDIUM — warming{/}"
  when 50...75 then "{#98c379-fg}▅ HIGH — cruising{/}"
  else              "{#61afef-fg}█ PEAK — full power{/}"
  end
end

Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Reactive signals — assign the value, every bound widget updates{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

panel = Widget::Box.new parent: s, top: 2, left: "center", width: 64, height: 19,
  label: " One Signal, four subscribers ",
  style: Style.new(border: true, fg: "#c0caf5", bg: "#10141c")

lcd = Widget::LCDNumber.new parent: panel, top: 1, left: "center", width: 16, height: 3,
  digit_count: 3, style: Style.new(fg: "#40e0d0", bg: "#10141c")

bar = Widget::ProgressBar.new parent: panel, top: 5, left: 2, width: 58, height: 3,
  text_visible: true, style: Style.new(border: true, fg: "#c0caf5", bg: "#10141c",
  indicator: Style.new(fg: "#2a6bd8", bg: "#10141c"))

meter = Widget::Box.new parent: panel, top: 8, left: 2, width: 58, height: 1,
  parse_tags: true, style: Style.new(fg: "#e5c07b", bg: "#10141c")

status_box = Widget::Box.new parent: panel, top: 10, left: 2, width: 58, height: 1,
  parse_tags: true, style: Style.new(bg: "#10141c")

Widget::Box.new parent: panel, top: 12, left: 2, width: 58, height: 5, parse_tags: true,
  style: Style.new(fg: "#8a93a8", bg: "#10141c"),
  content: "level = Reactive::Property.new 0\n" \
           "Reactive.bind(bar, level) { bar.value = level.value }\n" \
           "status = Reactive.computed { … level.value … }\n\n" \
           "s.every(0.1s) { level.value = sine(t) }   # that's all"

# --- wiring: each widget subscribes once; assignments do the rest -----------

# Explicit bindings: re-run whenever `level` changes, auto-disposed with the widget.
Reactive.bind(bar, level) { bar.value = level.value }
Reactive.bind(lcd, level) { lcd.display level.value }

# An effect auto-tracks what it reads — here the `status` computed.
Reactive.effect(status_box) { status_box.content = "{center}#{status.value}{/center}" }

# A second explicit binding drawing a tick meter from the same signal; its
# color follows the value through the same thresholds as the status line.
Reactive.bind(meter, level) do
  n = level.value * 56 // 100
  color = case level.value
          when 0...25  then "#e06c75"
          when 25...50 then "#e5c07b"
          when 50...75 then "#98c379"
          else              "#61afef"
          end
  meter.content = "{#{color}-fg}▕#{"■" * n}#{"·" * (56 - n)}▏{/}"
end

# --- driver: ONE assignment per tick; no widget is mentioned below ----------

t = 0.25
s.every(0.1.seconds) do
  level.value = ((Math.sin(t) * 0.5 + 0.5) * 100).round.to_i
  t += 0.09
end

s.exec
