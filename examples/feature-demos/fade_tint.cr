# IMPRESSIVE DEMO: opacity fades and color tints, all driven by the Animation
# engine (`Crysterm::Animation`) — the same tween/clock that powers media
# playback and effects.
#
# Four panels, each animating on its own over a hue-cycling backdrop, so the
# translucency and color overlays visibly compose with whatever is behind them
# (per-cell alpha blend):
#
#   • fade — pulse:     opacity breathes between 20% and 100%   (Widget#pulse)
#   • fade — in/out:    fades fully out, then back, forever      (fade_out/fade_in)
#   • tint — hue cycle: a color overlay whose hue sweeps the rainbow (style.tint)
#   • tint — pulse:     a fixed-color overlay whose strength pulses (Widget#tint_to)
#
# Set DEMO_SECONDS=N to auto-exit (for recording); otherwise press q / Ctrl-C.

require "../../src/crysterm"

include Crysterm

# A labeled, bordered panel with a solid background (so the overlays have
# something concrete to blend with).
def panel(screen, left, label, bg)
  Widget::Box.new \
    parent: screen, top: 3, left: left, width: 18, height: 7,
    content: "{center}\n\n#{label}{/center}", parse_tags: true,
    style: Style.new(fg: "white", bg: bg, border: true)
end

# Endlessly fade a widget out then back in (each leg eased), re-arming itself
# from the completion callback.
def fade_cycle(box)
  box.fade_out(0.8.seconds) { box.fade_in(0.8.seconds) { fade_cycle box } }
end

# Endlessly pulse a tint's strength up then back to zero, toward *color*.
def tint_cycle(box, color)
  box.tint_to(color, 0.85, 0.9.seconds) { box.tint_to(color, 0.0, 0.9.seconds) { tint_cycle box, color } }
end

s = Screen.new title: "Fades & Tints"

# Colorful, slowly hue-cycling backdrop so the fades/tints are visible.
Widget::Gradient.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  animate: true, speed: 0.01

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Fades & Tints — opacity and color overlays via the Animation engine{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#101820")

# 1. Opacity pulse — breathes between 20% and 100%.
panel(s, 2, "fade\npulse", "#203050").pulse 0.2, 1.0, 0.9.seconds

# 2. Fade fully out and back, forever.
fade_cycle panel(s, 22, "fade\nin / out", "#205040")

# 3. Tint overlay whose hue cycles through the rainbow at a fixed strength.
hue_panel = panel s, 42, "tint\nhue cycle", "#303030"
hue_panel.style.tint_alpha = 0.55
hue = 0.0
s.every(0.05.seconds) do
  hue += 6.0
  hue_panel.style.tint = Colors.hsv_i(hue)
end

# 4. Fixed-color tint whose strength pulses 0 → 85% → 0.
tint_cycle panel(s, 62, "tint\npulse", "#402030"), 0x33ccff

Widget::Box.new \
  parent: s, top: 11, left: 0, width: "100%", height: 1,
  content: "{center}press q or Ctrl-C to quit{/center}",
  parse_tags: true, style: Style.new(fg: "#a0b0c0", bg: "#101820")

if secs = ENV["DEMO_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.exec
