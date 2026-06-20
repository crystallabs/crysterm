require "../src/crysterm"

# TrueColor demo.
#
# Crysterm's native color space is 24-bit RGB, so colors given as hex strings
# (or {r,g,b}) are emitted verbatim as `38;2;r;g;b` on TrueColor terminals and
# only reduced to 256/16/8 colors when the terminal can't do better.
#
# Run it on a TrueColor terminal (e.g. with COLORTERM=truecolor) to see a smooth
# gradient; on a 256-color terminal the same code still works, just banded.
module Crysterm
  s = Screen.new

  depth = s.truecolor? ? "TrueColor (24-bit)" : "#{s.colors}-color"

  Widget::Box.new(
    parent: s,
    top: 0, left: 0, width: "100%", height: 1,
    content: " TrueColor demo — this terminal: #{depth}.  Press q to quit. ",
    style: Style.new(bg: "#202020", fg: "#ffffff"),
  )

  width = 64
  height = 8

  bar = Widget::Box.new(
    parent: s, top: 2, left: "center", width: width, height: height,
    style: Style.new(border: true),
  )

  # One column per step of a smooth RGB hue sweep — impossible to render without
  # losing detail on anything less than TrueColor.
  width.times do |i|
    t = i / (width - 1)
    r = (Math.sin(t * Math::PI) ** 2 * 255).to_i.clamp(0, 255)
    g = (Math.sin((t + 1.0/3) * Math::PI) ** 2 * 255).to_i.clamp(0, 255)
    b = (Math.sin((t + 2.0/3) * Math::PI) ** 2 * 255).to_i.clamp(0, 255)

    Widget::Box.new(
      parent: bar, top: 0, left: i, width: 1, height: height,
      style: Style.new(bg: sprintf("#%02x%02x%02x", r, g, b)),
    )
  end

  # Run headlessly (`-- --test-auto`) without blocking: render once and exit.
  if ARGV.includes? "--test-auto"
    s._render
    exit
  end

  s.on(Event::KeyPress) do |e|
    if e.char == 'q'
      s.destroy
      exit
    end
  end

  s.render

  s.exec
end
