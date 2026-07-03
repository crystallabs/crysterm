# A "nitro" — the *fastest-bar-none* twin of `cracktro.cr` / `quicktro.cr`.
# Pixel-for-pixel the same animation, produced by the shortest path to the
# terminal that exists in the framework.
#
# The three variants, fastest last:
#
#   cracktro.cr  ~1200 widgets (one Box per cell) + effect widgets. A stress
#                test: the compositor places and paints every widget each frame.
#
#   quicktro.cr  ONE widget whose `#render` writes finished cells straight into
#                the buffer with `fill_region`. Still goes through the window's
#                `_render` (compositor clear → the one widget paints → draw →
#                flush), so it stays capturable by the standard `.png`/`.apng`
#                harness. ~6× cheaper compositing than cracktro.
#
#   nitro.cr     NO widgets and NO compositor at all. Its own `FrameClock`
#                paints cells directly with `window.fill_region`, then pushes the
#                frame with `window.draw` (diff `@lines` vs `@olines`, encode,
#                write) — nothing else runs. This is the shortest path: no
#                buffer clear, no widget tree walk, no per-frame `_render`
#                bookkeeping. The full-screen scene overwrites every cell each
#                frame anyway, so the compositor's clear was pure waste here.
#
# The cost of "bar none": the standard headless capture is driven by the
# window's `_render` → `Event::Rendered` cycle (see `Window#capture_from_env`),
# which nitro never runs — so `Application#exec`'s capture path would snapshot a
# blank screen. nitro therefore drives its OWN capture too (paint a frame → read
# the buffer), below, guarded by the same env vars. In the interactive path it
# just paints and `draw`s in a tight loop.

require "../../src/crysterm"

include Crysterm

MSG = ("WELCOME TO THE CRYSTERM CRACKTRO !!!   GREETINGS TO:  BLESSED * " +
       "BLESSED-CONTRIB * QT * NCURSES (R.I.P.) * EVERY CRYSTAL CODER * " +
       "THE WHOLE DEMOSCENE ...   REAL ONES NEVER REMOVE THE INTRO !   ......   ")

GREET = "* CRACKED BY THE CRYSTERM CREW *"

PATTERN     = "CRYSTERM "
GROW        = ['.', '·', ':', '*', 'o', 'O', '0', '@']
INTERVAL    =  1
TRAVEL      = 12
HOLD        = 28
COPPER_ROWS = [1, 3]
BLACK       = 0x000000

# Clockwise spiral over every cell from the top-left corner (identical to the
# other two). Each successive cell is where one shot-out letter lands.
def spiral_order(w, h) : Array(Tuple(Int32, Int32))
  cells = [] of Tuple(Int32, Int32)
  top, bottom, left, right = 0, h - 1, 0, w - 1
  while top <= bottom && left <= right
    (left..right).each { |x| cells << {x, top} }
    top += 1
    (top..bottom).each { |y| cells << {right, y} }
    right -= 1
    if top <= bottom
      right.downto(left) { |x| cells << {x, bottom} }
      bottom -= 1
    end
    if left <= right
      bottom.downto(top) { |y| cells << {left, y} }
      left += 1
    end
  end
  cells
end

# Pack fg/bg (native `0xRRGGBB`, or -1 = terminal default) into a cell attr.
def cell_attr(fg, bg) : Int64
  Attr.pack(0, Attr.pack_color(fg), Attr.pack_color(bg))
end

# Paint one glyph string into a single row, one cell at a time (each a change-
# guarded 1x1 `fill_region`, so an unchanged overlay cell costs nothing).
def put_str(win, str, x, y, fg, bg)
  attr = cell_attr(fg, bg)
  str.each_char_with_index do |ch, i|
    win.fill_region attr, ch, x + i, x + i + 1, y, y + 1
  end
end

s = Window.new title: "CRYSTERM nitro", optimization: OptimizationFlag::None

# The buffer exists once the window is sized; make sure it is allocated whether
# we go interactive (via `exec`) or self-capture (below) without `exec`.
s.alloc

w = s.awidth
h = s.aheight
cx = w // 2
cy = h // 2
chars = MSG.chars
n = chars.size
letters_seq = PATTERN.chars.reject &.==(' ')
slots = spiral_order(w, h).map_with_index { |(x, y), i| {x, y, letters_seq[i % letters_seq.size]} }
cycle = slots.size * INTERVAL + TRAVEL + HOLD
row_bg = Array.new(h, BLACK)

# Perf figures for the overlay, updated each frame (they describe the *previous*
# frame, exactly like `Widget::Fps`).
stat_fps = 0_i64
stat_fps_avg = 0_i64
stat_render = 0_i64
stat_draw = 0_i64
stat_flush = 0_i64

# Paint the whole scene for `fr` straight into the window buffer. Identical math
# to `quicktro`'s single-widget render — copper bars, line scroller, flashing
# greet, sine scroller, and the centre-out letter spiral — just written to the
# window directly, with no compositor around it.
paint = ->(fr : Int64) do
  # The scene fills rows 1..h-1 every frame; only row 0's gaps stay at the
  # default background, so clear just that row (cheap) rather than the screen.
  s.fill_region cell_attr(-1, -1), ' ', 0, w, 0, 1

  # Copper rows: one solid hue-cycled band each, staggered 26° apart, +9°/frame.
  COPPER_ROWS.each_with_index do |row, idx|
    next unless row < h
    s.fill_region cell_attr(-1, Colors.hsv_i((idx * 26 + fr * 9) % 360)), ' ', 0, w, row, row + 1
  end

  # Per-row letter background (copper hue on the bar rows, else black).
  (0...h).each do |r|
    ci = COPPER_ROWS.index(r)
    row_bg[r] = ci ? Colors.hsv_i((ci * 26 + fr * 9) % 360) : BLACK
  end

  # Row 2: right-to-left rainbow line scroller.
  if 2 < h
    s.fill_region cell_attr(-1, BLACK), ' ', 0, w, 2, 3
    (0...w).each do |x|
      ch = chars[(fr + x) % n]
      next if ch == ' '
      s.fill_region cell_attr(Colors.hsv_i((x * 7 + fr * 8) % 360), BLACK), ch, x, x + 1, 2, 3
    end
  end

  # Row 4: flashing centered greet.
  if 4 < h
    s.fill_region cell_attr(-1, BLACK), ' ', 0, w, 4, 5
    fg = (fr // 4).even? ? 0xffff00 : 0xff3030
    gx = {(w - GREET.size) // 2, 0}.max
    GREET.chars.each_with_index do |ch, i|
      next if ch == ' '
      s.fill_region cell_attr(fg, BLACK), ch, gx + i, gx + i + 1, 4, 5
    end
  end

  # Rows 5..: sine-wave rainbow scroller.
  sine_top = 5
  if sine_top < h
    s.fill_region cell_attr(-1, BLACK), ' ', 0, w, sine_top, h
    sh = h - sine_top
    amp = (sh - 1) / 2.0
    (0...w).each do |x|
      ch = chars[(fr + x) % n]
      next if ch == ' '
      r = (amp * (1.0 + Math.sin(x * 0.32 + fr * 0.22))).round.to_i.clamp(0, sh - 1)
      s.fill_region cell_attr(Colors.hsv_i((x * 7 + fr * 6) % 360), BLACK), ch, x, x + 1, sine_top + r, sine_top + r + 1
    end
  end

  # Letters shot from the centre, spiralling clockwise to fill the screen.
  f = (fr % cycle).to_i
  slots.each_with_index do |slot, i|
    destx, desty, fch = slot
    lf = i * INTERVAL
    col, row = cx, cy
    if f < lf
      ch = '·'
      fg = (fr // 3).even? ? 0xff8080 : 0x80c0ff
    elsif f < lf + TRAVEL
      p = (f - lf) / TRAVEL.to_f
      col = (cx + (destx - cx) * p).round.to_i
      row = (cy + (desty - cy) * p).round.to_i
      ch = GROW[(p * GROW.size).to_i.clamp(0, GROW.size - 1)]
      fg = Colors.hsv_i((i * 9 + fr * 9) % 360)
    else
      col, row = destx, desty
      ch = fch
      fg = Colors.hsv_i((i * 9 + fr * 6) % 360)
    end
    s.fill_region cell_attr(fg, row_bg[row]), ch, col, col + 1, row, row + 1
  end

  # Overlay: same figures the `Fps` widget shows, computed by hand (there is no
  # `_render` to record them). Painted last, on top, like the real overlay.
  # `0xe5e5e5` is the palette's named "white" — what `Style.new(fg: "white")`
  # resolves to — so this matches quicktro's `Fps` widget exactly.
  put_str s, " FPS #{stat_fps} (avg #{stat_fps_avg})  render #{stat_render}  draw #{stat_draw}  flush #{stat_flush} ",
    0, 0, 0xe5e5e5, BLACK
end

rate = ->(span : Time::Span) {
  sec = span.total_seconds
  sec > 0 ? (1.0 / sec).to_i64 : 0_i64
}

# ---- headless capture (nitro drives it itself; see the header) --------------
shot = Config.window_shot.presence
dump_dest = Config.window_dump.presence
anim = Config.window_anim.presence

if shot || dump_dest || anim
  # Start at frame 0, so the captured artifacts line up with quicktro's (which
  # the standard harness captures before its first animation tick).
  # `NITRO_FRAME` overrides it (used by the parity check against quicktro).
  start_frame = ENV["NITRO_FRAME"]?.try(&.to_i64) || 0_i64
  paint.call start_frame

  s.capture(path: shot) if shot
  s.dump(path: dump_dest) if dump_dest

  if anim
    fr = start_frame
    # `capture(duration:)` snapshots the buffer on every `Event::Rendered`; nitro
    # has no `_render`, so it emits the event itself after painting each frame.
    clock = FrameClock.new(0.07.seconds) do
      fr += 1
      # Keep the overlay alive in the recording: time the paint as `render` and
      # the frame cadence as `fps` (there is no terminal draw/flush to time here).
      t0 = Time.instant
      paint.call fr
      stat_render = rate.call(Time.instant - t0)
      stat_fps = stat_fps_avg = (1.0 / 0.07).to_i64
      s.emit Crysterm::Event::Rendered
    end
    clock.start
    s.capture path: anim, duration: Config.window_anim_secs.seconds,
      fps: Config.window_anim_fps, loops: 0
    clock.stop
  end

  exit 0
end

# ---- interactive: paint → draw, no compositor --------------------------------
frame = 0_i64
last_start : Time::Instant? = nil

FrameClock.new(0.07.seconds) do
  t0 = Time.instant
  if prev = last_start
    stat_fps = rate.call(t0 - prev)
  end
  last_start = t0

  paint.call frame

  t1 = Time.instant
  s.draw flush: false
  t2 = Time.instant
  s.flush_frame
  t3 = Time.instant

  stat_render = rate.call(t1 - t0)
  stat_draw = rate.call(t2 - t1)
  stat_flush = rate.call(t3 - t2)
  # Simple running average of the frame rate for the "(avg …)" field.
  stat_fps_avg = frame > 0 ? (stat_fps_avg * (frame - 1) + stat_fps) // frame : stat_fps

  frame += 1
end.start

s.exec
