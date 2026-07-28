# FEATURE: multiple screens/windows from one app.
#
# One Crysterm process can drive several surfaces at once: `Application.open`
# spawns a real terminal-emulator window and returns a `Window` for it,
# `Application.run(window_count: N)` opens N of them, and
# `Application.exec_all(windows)` runs any set of windows under one shared
# event loop and graceful quit. Windows can also share one `Screen` (device),
# or migrate between devices with `Window#connect` / `#disconnect`.
#
# A shared `Reactive::Signal` is the bridge: assign `value =` in one window
# and every widget bound to it — in *any* window — updates automatically.
#
# Run modes:
#   crystal multiple.cr              one terminal, both screens depicted side
#                                    by side (also what the capture shows)
#   crystal multiple.cr -- --spawn   two REAL terminal windows via
#                                    Application.run(window_count: 2)
#
# In both modes the code below builds the same two panels wired to the same
# signal — only where they render differs.

require "../../../src/crysterm"

include Crysterm

# The shared state: one reactive value, bound into both windows.
volume = Reactive::Signal.new 40

# --- Panel builders (identical in both run modes) ----------------------------

# "Screen 1": owns the value; its slider assigns `volume.value`.
def build_sender(parent, volume)
  Widget::Box.new parent: parent, top: 1, left: 2, width: "100%-4", height: 4,
    parse_tags: true,
    content: "{bold}Screen 1{/bold} — {#57c7ff-fg}sender{/}\n" \
             "Its own terminal device,\nwith its own window. Drag\nor key the slider:"
  slider = Widget::Slider.new parent: parent, top: 6, left: 2, width: "100%-4", height: 2,
    minimum: 0, maximum: 100, value: volume.value, text_visible: true,
    tick_position: Widget::Slider::TickPosition::Below, tick_interval: 25
  slider.on(Event::ValueChanged) { volume.value = slider.value }
  Widget::Box.new parent: parent, bottom: 1, left: 2, width: "100%-4", height: 2,
    parse_tags: true,
    content: "{#8a94a6-fg}slider.on(ValueChanged) {\n  volume.value = slider.value }{/}"
  slider
end

# "Screen 2": pure receiver; bindings update it on every assignment.
def build_receiver(parent, volume)
  Widget::Box.new parent: parent, top: 1, left: 2, width: "100%-4", height: 4,
    parse_tags: true,
    content: "{bold}Screen 2{/bold} — {#98c379-fg}receiver{/}\n" \
             "Nothing here is set directly;\nit follows the shared\nsignal:"
  bar = Widget::ProgressBar.new parent: parent, top: 6, left: 2, width: "100%-4", height: 1,
    value: volume.value
  lcd = Widget::LCDNumber.new parent: parent, top: 8, left: 2, width: 16, height: 3,
    digit_count: 3
  lcd.display volume.value
  Reactive.bind bar, volume do
    bar.value = volume.value
    lcd.display volume.value
  end
  Widget::Box.new parent: parent, bottom: 1, left: 2, width: "100%-4", height: 2,
    parse_tags: true,
    content: "{#8a94a6-fg}Reactive.bind(bar, volume) {\n  bar.value = volume.value }{/}"
end

# Demo driver: sweep the value so the propagation is visible hands-free.
def drive(window, slider)
  t = 0.0
  window.every(0.1.seconds) do
    slider.value = (50 + 49 * Math.sin(t)).to_i
    t += 0.35
  end
end

# --- Mode 1: two real terminal windows ---------------------------------------

if ARGV.includes? "--spawn"
  slider = nil
  Application.run(window_count: 2, cols: 44, rows: 16) do |w, i|
    frame = Widget::Box.new parent: w, top: 0, left: 0, width: "100%", height: "100%",
      style: Style.new(border: true)
    if i.zero?
      slider = build_sender frame, volume
    else
      build_receiver frame, volume
      # The windows are built in order, so the sender's slider exists by now.
      slider.try { |sl| drive w, sl }
    end
  end
  exit
end

# --- Mode 2: one terminal, the two screens depicted side by side -------------

s = Window.new title: "Multiple screens"

Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1, parse_tags: true,
  content: "{center}{bold}Two screens, one app{/bold} — synced by a shared" \
           " {#57c7ff-fg}Reactive::Signal{/}{/center}"

left = Widget::Box.new parent: s, top: 2, left: 1, width: 38, height: 20,
  style: Style.new(border: true), label: " Screen 1 "
right = Widget::Box.new parent: s, top: 2, left: 41, width: 38, height: 20,
  style: Style.new(border: true), label: " Screen 2 "

slider = build_sender left, volume
build_receiver right, volume
drive s, slider

Widget::Box.new parent: s, bottom: 0, left: 0, width: "100%", height: 1, parse_tags: true,
  content: "{center}{#8a94a6-fg}run with --spawn to open two real terminal windows{/}{/center}"

s.exec
