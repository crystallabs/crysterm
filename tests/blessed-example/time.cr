require "../../src/crysterm"

# Port of blessed's `example/time.js` — a big "seven-segment" clock.
#
# Each glyph (0-9, ':', a/p/m) is a parent cell box with coloured child boxes
# forming the lit segments. Unlike blessed (which pre-builds every glyph),
# glyphs here are built lazily and cached per (column, character), then
# repositioned + shown each tick — same visual result.
#
# Flags (like the original):
#   -s         show seconds
#   -n         no leading zero on the hour
#   -d         show an ISO date box
#   --skinny   thinner vertical strokes
#
# Quit with q.

include Crysterm
include Crysterm::Widgets

module Clock
  extend self

  WID = ARGV.includes?("--skinny") ? 1 : 2

  # A segment rectangle inside a glyph cell. Any of the six may be nil (unset).
  # Explicit param types keep every `seg` the same NamedTuple type so they can
  # live in one array and be `**`-splatted.
  def seg(top : Int32? = nil, left : Int32 | String | Nil = nil, right : Int32? = nil,
          bottom : Int32? = nil, width : Int32? = nil, height : Int32? = nil)
    {top: top, left: left, right: right, bottom: bottom, width: width, height: height}
  end

  # Cell size / placement / colour for a drawable character (nil = blank).
  def meta(c : Char)
    case c
    when '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'
      {width: 10, top: 0, height: 9, color: "white"}
    when ':' then {width: 5, top: 0, height: 9, color: "white"}
    when 'a' then {width: 10, top: 2, height: 7, color: "blue"}
    when 'p' then {width: 10, top: 2, height: 7, color: "blue"}
    when 'm' then {width: 10, top: 2, height: 7, color: "blue"}
    else          nil
    end
  end

  # The lit segments for each glyph (w = stroke width).
  def segments(c : Char)
    w = WID
    case c
    when '0' then [seg(top: 0, left: 0, right: 0, height: 1), seg(top: 0, left: 0, bottom: 0, width: w), seg(top: 0, right: 0, bottom: 0, width: w), seg(top: 8, left: 0, right: 0, height: 1)]
    when '1' then [seg(top: 0, bottom: 0, left: "center", width: w)]
    when '2' then [seg(top: 0, left: 0, right: 0, height: 1), seg(top: 0, right: 0, height: 4, width: w), seg(top: 4, left: 0, right: 0, height: 1), seg(top: 4, left: 0, height: 4, width: w), seg(top: 8, left: 0, right: 0, height: 1)]
    when '3' then [seg(top: 0, bottom: 0, right: 0, width: w), seg(top: 0, left: 0, right: 0, height: 1), seg(top: 4, left: 0, right: 0, height: 1), seg(top: 8, left: 0, right: 0, height: 1)]
    when '4' then [seg(top: 0, bottom: 0, right: 0, width: w), seg(top: 4, left: 0, right: 0, height: 1), seg(top: 0, left: 0, width: w, height: 4)]
    when '5' then [seg(top: 0, left: 0, right: 0, height: 1), seg(top: 0, left: 0, height: 4, width: w), seg(top: 4, left: 0, right: 0, height: 1), seg(top: 4, right: 0, height: 4, width: w), seg(top: 8, left: 0, right: 0, height: 1)]
    when '6' then [seg(top: 0, left: 0, right: 0, height: 1), seg(top: 0, left: 0, bottom: 0, width: w), seg(top: 4, left: 0, right: 0, height: 1), seg(top: 4, right: 0, height: 4, width: w), seg(top: 8, left: 0, right: 0, height: 1)]
    when '7' then [seg(top: 0, bottom: 0, right: 0, width: w), seg(top: 0, left: 0, right: 0, height: 1)]
    when '8' then [seg(top: 0, left: 0, right: 0, height: 1), seg(top: 0, left: 0, bottom: 0, width: w), seg(top: 4, left: 0, right: 0, height: 1), seg(top: 0, right: 0, bottom: 0, width: w), seg(top: 8, left: 0, right: 0, height: 1)]
    when '9' then [seg(top: 0, left: 0, right: 0, height: 1), seg(top: 0, left: 0, height: 4, width: w), seg(top: 4, left: 0, right: 0, height: 1), seg(top: 0, right: 0, bottom: 0, width: w), seg(top: 8, left: 0, right: 0, height: 1)]
    when ':' then [seg(top: 3, left: "center", width: w, height: 1), seg(top: 6, left: "center", width: w, height: 1)]
    when 'a' then [seg(top: 0, left: 0, right: 0, height: 1), seg(top: 0, left: 0, bottom: 0, width: w), seg(top: 3, left: 0, right: 0, height: 1), seg(top: 0, right: 0, bottom: 0, width: w)]
    when 'p' then [seg(top: 0, left: 0, right: 0, height: 1), seg(top: 0, right: 0, height: 4, width: w), seg(top: 0, left: 0, bottom: 0, width: w), seg(top: 3, left: 0, right: 0, height: 1)]
    when 'm' then [seg(top: 0, left: 0, right: 0, height: 1), seg(top: 0, left: 0, bottom: 0, width: w), seg(top: 0, right: 0, bottom: 0, width: w), seg(top: 0, bottom: 0, left: "center", width: w)]
    else          [] of typeof(seg)
    end
  end
end

seconds = ARGV.includes?("-s")
no_zero = ARGV.includes?("-n")
show_date = ARGV.includes?("-d")

window = Window.new title: "time.cr"

container = Widget::Box.new parent: window, top: "center", left: 0, width: "100%", height: 9

date = Widget::Box.new parent: window, top: 1, left: 1, width: 26, height: 3,
  style: Style.new(border: true)
date.hide

# Built glyphs cached by (column index, char); the set currently visible.
cache = {} of Tuple(Int32, Char) => Widget::Box
shown = [] of Widget::Box
last_time = ""

build_glyph = ->(c : Char) {
  m = Clock.meta(c).not_nil!
  g = Widget::Box.new parent: container, top: m[:top], left: 0, width: m[:width], height: m[:height]
  st = Style.new(bg: m[:color])
  Clock.segments(c).each do |s|
    Widget::Box.new parent: g, style: st,
      top: s[:top], left: s[:left], right: s[:right],
      bottom: s[:bottom], width: s[:width], height: s[:height]
  end
  g.hide
  g
}

update = -> {
  now = Time.local
  h = now.hour
  im = h >= 12 ? "pm" : "am"
  h -= 12 if h > 12
  h = 12 if h == 0
  hh = h < 10 ? "0#{h}" : h.to_s
  mm = now.minute < 10 ? "0#{now.minute}" : now.minute.to_s
  ss = now.second < 10 ? "0#{now.second}" : now.second.to_s
  time = seconds ? "#{hh}:#{mm}:#{ss}#{im}" : "#{hh}:#{mm}#{im}"

  return if time == last_time
  last_time = time

  chars = time.chars
  chars[0] = ' ' if no_zero && chars[0] == '0'

  shown.each &.hide
  shown.clear

  total = chars.sum { |c| (mt = Clock.meta(c)) ? mt[:width] + 2 : 0 }
  total -= 2 if total > 0
  pos = Math.max(0, (window.awidth - total) // 2)

  chars.each_with_index do |c, i|
    m = Clock.meta(c)
    next unless m
    g = cache[{i, c}] ||= build_glyph.call(c)
    g.clear_last_rendered_position
    g.left = pos
    g.show
    shown << g
    pos += m[:width] + 2
  end

  if show_date
    date.content = now.to_s("%Y-%m-%dT%H:%M:%S")
    date.show
  end
}

# `update` early-returns when the time is unchanged, but a resize needs a
# recompute of the horizontal position, so clear the cached time first.
window.on(Event::Resize) do
  last_time = ""
  update.call
end

update.call
window.every((seconds ? 0.1 : 0.95).seconds) { update.call }

window.exec
