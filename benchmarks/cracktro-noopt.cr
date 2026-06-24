# Full-recomposite-only variant of cracktro-profile.cr for bisecting commits that
# PREDATE the OptimizationFlag param. Constructs the scene without `optimization:`
# and just calls `_render` N times (the only/legacy render path). Same scene and
# per-frame mutation as the demo.
#
# Run:  crystal run --release benchmarks/cracktro-noopt.cr

require "../src/crysterm"
include Crysterm

WIDTH  =  80
HEIGHT =  15
FRAMES = 600

MSG = ("WELCOME TO THE CRYSTERM CRACKTRO !!!   GREETINGS TO:  BLESSED * " +
       "BLESSED-CONTRIB * QT * NCURSES (R.I.P.) * EVERY CRYSTAL CODER * " +
       "THE WHOLE DEMOSCENE ...   REAL ONES NEVER REMOVE THE INTRO !   ......   ")

PATTERN  = "CRYSTERM "
GROW     = [".", "·", ":", "*", "o", "O", "0", "@"]
INTERVAL =  1
TRAVEL   = 12
HOLD     = 28

def spiral_order(w, h)
  cells = [] of Tuple(Int32, Int32)
  top = 0; bottom = h - 1; left = 0; right = w - 1
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

s = Screen.new(
  input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: WIDTH, height: HEIGHT)
w = s.awidth
h = s.aheight

copper_idx = {1 => 0, 3 => 1}
copper = [1, 3].map_with_index do |row, idx|
  Widget::Effect::CopperBar.new parent: s, top: row, left: 0, width: "100%", height: 1,
    hue_offset: idx * 26, hue_speed: 9
end

hscroll = Widget::Marquee.new parent: s, top: 2, left: 0, width: "100%", height: 1,
  text: MSG, rainbow: true, style: Style.new(bg: "black")

greet = Widget::Box.new parent: s, top: 4, left: 0, width: "100%", height: 1, align: :hcenter,
  content: "* CRACKED BY THE CRYSTERM CREW *", style: Style.new(fg: "yellow", bg: "black")

sine_top = 5
sine = Widget::Effect::SineScroller.new parent: s, top: sine_top, left: 0, width: "100%",
  height: h - sine_top, text: MSG, style: Style.new(bg: "black")

row_bg = Array.new(h, 0x000000)
refresh_row_bg = ->(fr : Int32) {
  (0...h).each do |r|
    row_bg[r] = (ci = copper_idx[r]?) ? Colors.hsv_i((ci * 26 + fr * 9) % 360) : 0x000000
  end
}

cx = w // 2
cy = h // 2
letters_seq = PATTERN.chars.reject { |c| c == ' ' }
slots = spiral_order(w, h).map_with_index do |(x, y), i|
  {x, y, letters_seq[i % letters_seq.size]}
end
cycle = slots.size * INTERVAL + TRAVEL + HOLD

letters = slots.map do |_|
  Widget::Box.new parent: s, top: cy, left: cx, width: 1, height: 1,
    content: "·", style: Style.new(fg: 0xffffff, bg: 0x000000)
end

frame = 0
step = -> {
  copper.each &.step
  hscroll.step
  greet.style.fg = (frame // 4).even? ? 0xffffff : 0xff3030
  sine.step
  refresh_row_bg.call frame
  f = frame % cycle
  letters.each_with_index do |box, i|
    destx, desty, fch = slots[i]
    lf = i * INTERVAL
    col = cx; row = cy
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
      col = destx; row = desty
      box.content = fch.to_s
      box.style.fg = Colors.hsv_i((i * 9 + frame * 6) % 360)
    end
    box.left = col
    box.top = row
    box.style.bg = row_bg[row]
  end
  frame += 1
}

5.times { step.call; s._render }

GC.collect
before = GC.stats.total_bytes
rsum = 0_i64
wall = Time.measure do
  FRAMES.times do
    step.call
    s._render
    rsum += s.render_rate
  end
end
alloc = GC.stats.total_bytes - before

STDERR.printf "FULL-PATH  wall/frame: %7.1f µs   alloc/frame: %8d bytes   render-eq %d fps\n",
  wall.total_microseconds / FRAMES, alloc // FRAMES, rsum // FRAMES
