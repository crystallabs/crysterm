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
# Below them: a static row of the four per-cell `Attr::Alpha` compositing modes
# (Opaque / Blend / Transparent / HighContrast) via `Colors.composite`; a
# `z-index` overlay demonstrating the plane compositor (panels animate *through*
# a translucent layer that paints opaquely); and a row showing declarative CSS
# `transition` (auto-toggled :hover) and `@keyframes` animation.
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

s = Screen.new title: "Fades, Tints & Alpha"

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

# 5. Per-cell ALPHA MODES — the four `Attr::Alpha` modes folded over one common
# background via `Colors.composite` (the per-cell primitive the plane compositor
# will use). Shown as static swatches: Opaque = the source color, Blend = 50/50,
# Transparent = the background shows through, HighContrast = auto black/white.
Widget::Box.new \
  parent: s, top: 10, left: 0, width: "100%", height: 1,
  content: "{center}per-cell alpha modes — Colors.composite(source, background){/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#101820")

source = 0xffcc00 # amber source color
under = Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(0x2a3050))
[{"opaque", Attr::Alpha::Opaque},
 {"blend", Attr::Alpha::Blend},
 {"transparent", Attr::Alpha::Transparent},
 {"high-contrast", Attr::Alpha::HighContrast}].each_with_index do |(name, mode), i|
  top = Attr.with_bg_alpha(Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(source)), mode)
  swatch = Attr.unpack_color(Attr.bg(Colors.composite(top, under)))
  Widget::Box.new \
    parent: s, top: 11, left: 2 + i * 19, width: 18, height: 3,
    content: "{center}\n#{name}{/center}", parse_tags: true,
    style: Style.new(fg: Colors.readable_on(swatch, 0x000000, 0xffffff), bg: swatch, border: true)
end

# 6. The PLANE COMPOSITOR (Step 6): a `z-index` promotes this overlay to its own
# plane and `opacity` composites the whole plane over the base — so although it
# paints opaquely, the live panels animate *through* it. The flat painter's
# algorithm can't do this for an opaque widget; only a real compositor can.
# Driven entirely from CSS — `z-index` is what makes a widget a layer.
s.stylesheet = <<-CSS
  .xray { background-color: #eaf2ff; color: #0c1830; border: solid; z-index: 50; opacity: 0.30; }
  /* 7a. CSS transition — auto-toggled :hover state animates the color. */
  .hov { background-color: #203050; color: white; border: solid; transition: background-color 0.5s ease-in-out; }
  .hov:hover { background-color: #d04060; }
  /* 7b. CSS @keyframes animation — declarative, looping. */
  @keyframes breathe { from { opacity: 0.35; } to { opacity: 1.0; } }
  .kf { background-color: #2a4030; color: white; border: solid; animation: breathe 1.4s ease-in-out infinite alternate; }
  CSS
Widget::Box.new(
  parent: s, top: 4, left: 21, width: 40, height: 5,
  content: "{center}\n\nz-index overlay — panels animate through this translucent plane{/center}",
  parse_tags: true).add_css_class "xray"

# 7. Declarative CSS animation. Left box: a `transition` triggered by toggling
# its :hover state on a timer (watch the color ease). Right box: a looping
# `@keyframes` opacity animation (no triggering needed).
hov = Widget::Box.new parent: s, top: 15, left: 2, width: 36, height: 3,
  content: "{center}\ncss transition (auto :hover){/center}", parse_tags: true
hov.add_css_class "hov"
s.every(1.0.seconds) do
  hov.state = hov.state.hovered? ? Crysterm::WidgetState::Normal : Crysterm::WidgetState::Hovered
end

Widget::Box.new(parent: s, top: 15, left: 40, width: 38, height: 3,
  content: "{center}\ncss @keyframes (looping)){/center}", parse_tags: true).add_css_class "kf"

Widget::Box.new \
  parent: s, top: 19, left: 0, width: "100%", height: 1,
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
