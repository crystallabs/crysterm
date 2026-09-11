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

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new title: "Reactive"

# The single piece of application state. (Starts mid-wave so even the very
# first frame shows the widgets tracking a live value.)
level = CT::Reactive::Property.new 62

# Signals derived from `level`, recomputed only when it changes.
status = CT::Reactive.computed do
  case level.value
  when 0...25  then "{#e06c75-fg}▁ LOW — spinning up{/}"
  when 25...50 then "{#e5c07b-fg}▃ MEDIUM — warming{/}"
  when 50...75 then "{#98c379-fg}▅ HIGH — cruising{/}"
  else              "{#61afef-fg}█ PEAK — full power{/}"
  end
end

CW::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Reactive signals — assign the value, every bound widget updates{/center}",
  parse_tags: true, style: CT::Style.new(fg: "white", bg: "#202830")

panel = CW::Box.new parent: s, top: 2, left: "center", width: 64, height: 19,
  label: " One Signal, four subscribers ",
  style: CT::Style.new(border: true, fg: "#c0caf5", bg: "#10141c")

lcd = CW::LCDNumber.new parent: panel, top: 1, left: "center", width: 16, height: 3,
  digit_count: 3, style: CT::Style.new(fg: "#40e0d0", bg: "#10141c")

bar = CW::ProgressBar.new parent: panel, top: 5, left: 2, width: 58, height: 3,
  text_visible: true, style: CT::Style.new(border: true, fg: "#c0caf5", bg: "#10141c",
  indicator: CT::Style.new(fg: "#2a6bd8", bg: "#10141c"))

meter = CW::Box.new parent: panel, top: 8, left: 2, width: 58, height: 1,
  parse_tags: true, style: CT::Style.new(fg: "#e5c07b", bg: "#10141c")

status_box = CW::Box.new parent: panel, top: 10, left: 2, width: 58, height: 1,
  parse_tags: true, style: CT::Style.new(bg: "#10141c")

CW::Box.new parent: panel, top: 12, left: 2, width: 58, height: 5,
  style: CT::Style.new(fg: "#8a93a8", bg: "#10141c"),
  content: "level = Reactive::Property.new 0\n" \
           "Reactive.bind(bar, level) { bar.value = level.value }\n" \
           "status = Reactive.computed { … level.value … }\n\n" \
           "s.every(0.1s) { level.value = sine(t) }   # that's all"

# --- wiring: each widget subscribes once; assignments do the rest -----------

# Explicit bindings: re-run whenever `level` changes, auto-disposed with the widget.
CT::Reactive.bind(bar, level) { bar.value = level.value }
CT::Reactive.bind(lcd, level) { lcd.display level.value }

# An effect auto-tracks what it reads — here the `status` computed.
CT::Reactive.effect(status_box) { status_box.content = "{center}#{status.value}{/center}" }

# A second explicit binding drawing a tick meter from the same signal; its
# color follows the value through the same thresholds as the status line.
CT::Reactive.bind(meter, level) do
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
