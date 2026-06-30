# IMPRESSIVE DEMO: a "cracktro" — the animated intro old-school crackers bolted
# onto pirated games. Standard 80x15 window.
#
# Letters are shot out of the CRT centre dot and land in a clockwise spiral that
# fills the WHOLE screen: the top row first, then down the right border, the
# bottom row right→left, up the left border, then inward (2nd row, ...) until
# every cell is filled — at which point it resets and starts over clean. Each
# letter fakes growing (. · : * o O 0 @) and adopts the background it flies over.
#
# Underneath, the scene plays on until the spiral covers it:
#   row 1 : copper / raster bar
#   row 2 : a plain right-to-left text scroller (same message as the sine one)
#   row 3 : copper / raster bar
# Then a flashing greet, and the classic sine-wave rainbow scroller below.

require "../../src/crysterm"

include Crysterm

# This is a full-screen animation: every cell changes every frame (copper bars,
# scrollers, and the spiral of per-cell letters all recolor continuously), and
# the scene mutates `style.fg`/`bg` in place. Damage tracking (the default) can
# never win here — selective repaint degenerates to the whole screen — so it only
# pays per-frame bookkeeping (per-child damage bounds, dirty-set maintenance):
# ~8-10% of render time measured on this scene. `OptimizationFlag::None` repaints
# the whole buffer every frame, which is both faster here AND more correct (a
# full composite always picks up the in-place style mutations that damage
# tracking, keyed on explicit dirty marks, would miss).
s = Window.new title: "CRYSTERM cracktro", optimization: OptimizationFlag::None

w = s.awidth
h = s.aheight

MSG = ("WELCOME TO THE CRYSTERM CRACKTRO !!!   GREETINGS TO:  BLESSED * " +
       "BLESSED-CONTRIB * QT * NCURSES (R.I.P.) * EVERY CRYSTAL CODER * " +
       "THE WHOLE DEMOSCENE ...   REAL ONES NEVER REMOVE THE INTRO !   ......   ")

# Copper bars on rows 1 and 3 (rows 0 and 2 carry the title and the line
# scroller), as reusable `Widget::Effect::CopperBar`s. Each is staggered around
# the color wheel by `hue_offset` and advanced explicitly from the master loop
# below (via `step`) so the whole scene stays on one clock — `bg_under` recomputes
# the very same hue independently, so flying letters ride over the bars seamlessly.
COPPER_ROWS = [1, 3]
copper = COPPER_ROWS.map_with_index do |row, idx|
  Widget::Effect::CopperBar.new parent: s, top: row, left: 0, width: "100%", height: 1,
    hue_offset: idx * 26, hue_speed: 9
end
copper_idx = {1 => 0, 3 => 1}

# Row 2: right-to-left rainbow scroller of the same message, as a reusable
# `Widget::Marquee`. Its frame is advanced explicitly from the master loop below
# (via `step`, rather than `start` and its own fiber) so it stays locked to the
# same clock as the rest of the scene and the recorded GIF still tiles seamlessly.
hscroll = Widget::Marquee.new \
  parent: s, top: 2, left: 0, width: "100%", height: 1,
  text: MSG, rainbow: true, style: Style.new(bg: "black")

# Flashing greet.
greet = Widget::Box.new \
  parent: s, top: 4, left: 0, width: "100%", height: 1, align: :hcenter,
  content: "* CRACKED BY THE CRYSTERM CREW *", style: Style.new(fg: "yellow", bg: "black")

# Sine-wave rainbow scroller in the lower portion, as a reusable
# `Widget::Effect::SineScroller`. Advanced from the master loop via `step` so it
# shares the one frame clock (keeping the recorded GIF seamless).
sine_top = 5
sine = Widget::Effect::SineScroller.new \
  parent: s, top: sine_top, left: 0, width: "100%", height: h - sine_top,
  text: MSG, style: Style.new(bg: "black")

# Background present at each row for the current frame, so a flying letter can
# adopt it and ride over the scene without changing the background it passes
# across: the copper rows carry the current raster-bar hue, every other row is
# black. Recomputed once per row each frame (`refresh_row_bg`) and then read by
# index in the per-cell loop — turning what used to be a `Hash` lookup + an
# `hsv` *string* (re-parsed by `style.bg=`) on every one of the screen's cells
# into a single array read. (`hsv_i` yields the native `0xRRGGBB` int directly.)
row_bg = Array.new(h, 0x000000)
refresh_row_bg = ->(fr : Int32) {
  (0...h).each do |r|
    row_bg[r] = (ci = copper_idx[r]?) ? Colors.hsv_i((ci * 26 + fr * 9) % 360) : 0x000000
  end
}

# The top row is the title: "CRYSTERM " repeated across the whole width, every
# non-space cell a letter shot from the centre.
PATTERN  = "CRYSTERM "
GROW     = [".", "·", ":", "*", "o", "O", "0", "@"]
INTERVAL =  1 # frames between successive letter launches (rapid: fills the screen)
TRAVEL   = 12 # frames a letter spends in flight
HOLD     = 28 # frames the finished row is held before re-firing

cx = w // 2
cy = h // 2

# Clockwise spiral over every cell, starting at the top-left corner: the top row
# left→right, then down the right border, the bottom row right→left, up the left
# border, and then inward (2nd row from the top, ...) until the whole screen is
# filled. Each successive cell is the destination of one shot-out letter.
def spiral_order(w, h)
  cells = [] of Tuple(Int32, Int32)
  top = 0
  bottom = h - 1
  left = 0
  right = w - 1
  while top <= bottom && left <= right
    (left..right).each { |x| cells << {x, top} } # top row, L→R
    top += 1
    (top..bottom).each { |y| cells << {right, y} } # right border, T→B
    right -= 1
    if top <= bottom
      right.downto(left) { |x| cells << {x, bottom} } # bottom row, R→L
      bottom -= 1
    end
    if left <= right
      bottom.downto(top) { |y| cells << {left, y} } # left border, B→T
      left += 1
    end
  end
  cells
end

# Every cell receives a (non-space) letter so the screen fills in solid.
LETTERS_SEQ = PATTERN.chars.reject { |c| c == ' ' }
slots = spiral_order(w, h).map_with_index do |(x, y), i|
  {x, y, LETTERS_SEQ[i % LETTERS_SEQ.size]}
end
cycle = slots.size * INTERVAL + TRAVEL + HOLD

letters = slots.map do |_|
  Widget::Box.new parent: s, top: cy, left: cx, width: 1, height: 1,
    content: "·", style: Style.new(fg: 0xffffff, bg: 0x000000)
end

# Live performance overlay. Added last so it paints on top of the scene; it
# updates itself from the screen's render stats each frame (no `step` needed).
# Anchored top-left here (its default is bottom-left, where the sine scroller is).
Widget::Fps.new \
  parent: s, top: 0, left: 0,
  format: " FPS %s (avg %s)  render %s  draw %s ",
  args: %i[fps fps_avg render draw],
  style: Style.new(fg: "white", bg: "black")

frame = 0
s.every(0.07.seconds) do
  # copper bars hue-cycle (advance one frame; each CopperBar paints its own bg)
  copper.each &.step

  # row 2: right-to-left rainbow scroller (advance one column per master frame)
  hscroll.step

  greet.style.fg = (frame // 4).even? ? 0xffff00 : 0xff3030

  # sine-wave rainbow scroller (advance one column per master frame)
  sine.step

  # per-row background for this frame (copper hue on the bar rows, else black)
  refresh_row_bg.call frame

  # letters shot from the centre dot, spiralling clockwise to fill the screen
  f = frame % cycle
  letters.each_with_index do |box, i|
    destx, desty, fch = slots[i]
    lf = i * INTERVAL
    col = cx
    row = cy
    if f < lf
      box.content = "·"
      box.style.fg = (frame // 3).even? ? 0xff8080 : 0x80c0ff
    elsif f < lf + TRAVEL
      p = (f - lf) / TRAVEL.to_f
      col = (cx + (destx - cx) * p).round.to_i
      row = (cy + (desty - cy) * p).round.to_i
      box.content = GROW[(p * GROW.size).to_i.clamp(0, GROW.size - 1)]
      box.style.fg = Colors.hsv_i((i * 9 + frame * 9) % 360)
    else
      col = destx
      row = desty
      box.content = fch.to_s
      box.style.fg = Colors.hsv_i((i * 9 + frame * 6) % 360)
    end
    box.left = col
    box.top = row
    box.style.bg = row_bg[row]
  end

  frame += 1
end

s.exec
