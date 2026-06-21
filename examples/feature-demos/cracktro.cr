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

s = Screen.new title: "CRYSTERM cracktro"
s.show_fps = nil

w = s.awidth
h = s.aheight

def hsv(hh : Int32) : String
  x = (255 * (1 - ((hh / 60.0) % 2 - 1).abs)).to_i.clamp(0, 255)
  r, g, b = case (hh // 60) % 6
            when 0 then {255, x, 0}
            when 1 then {x, 255, 0}
            when 2 then {0, 255, x}
            when 3 then {0, x, 255}
            when 4 then {x, 0, 255}
            else        {255, 0, x}
            end
  "#%02x%02x%02x" % {r, g, b}
end

MSG = ("WELCOME TO THE CRYSTERM CRACKTRO !!!   GREETINGS TO:  BLESSED * " +
       "BLESSED-CONTRIB * QT * NCURSES (R.I.P.) * EVERY CRYSTAL CODER * " +
       "THE WHOLE DEMOSCENE ...   REAL ONES NEVER REMOVE THE INTRO !   ......   ")

# Copper bars on rows 1 and 3 (rows 0 and 2 carry the title and the line scroller).
COPPER_ROWS = [1, 3]
copper = COPPER_ROWS.map do |row|
  Widget::Box.new parent: s, top: row, left: 0, width: "100%", height: 1,
    style: Style.new(bg: "#000000")
end
copper_idx = {1 => 0, 3 => 1}

# Row 2: plain right-to-left scroller of the same message.
hscroll = Widget::Box.new \
  parent: s, top: 2, left: 0, width: "100%", height: 1,
  content: "", parse_tags: true, style: Style.new(bg: "black")

# Flashing greet.
greet = Widget::Box.new \
  parent: s, top: 4, left: 0, width: "100%", height: 1, align: :hcenter,
  content: "* CRACKED BY THE CRYSTERM CREW *", style: Style.new(fg: "yellow", bg: "black")

# Sine-wave rainbow scroller in the lower portion.
sine_top = 5
band_h = h - sine_top
sine = Widget::Box.new \
  parent: s, top: sine_top, left: 0, width: "100%", height: band_h,
  content: "", parse_tags: true, style: Style.new(bg: "black")

# Background already present at a given row, so a flying letter can adopt it and
# ride over the scene without changing the background it passes across.
bg_under = ->(row : Int32, fr : Int32) {
  if ci = copper_idx[row]?
    hsv((ci * 26 + fr * 9) % 360)
  else
    "#000000"
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
    content: "·", style: Style.new(fg: "#ffffff", bg: "#000000")
end

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

amp = (band_h - 1) / 2.0
frame = 0
spawn do
  loop do
    # copper bars scroll
    copper.each_with_index do |box, idx|
      box.style.bg = hsv(((idx * 26) + frame * 9) % 360)
    end

    # row 2: right-to-left line scroller
    hscroll.content = String.build do |io|
      (0...w).each do |x|
        ch = MSG[(frame + x) % MSG.size]
        if ch == ' '
          io << ' '
        else
          io << "{#{hsv((x * 7 + frame * 8) % 360)}-fg}" << ch << "{/}"
        end
      end
    end

    greet.style.fg = (frame // 4).even? ? "#ffffff" : "#ff3030"

    # sine-wave rainbow scroller
    grid = Array.new(band_h) { Array(String?).new(w, nil) }
    (0...w).each do |x|
      ch = MSG[(frame + x) % MSG.size]
      next if ch == ' '
      r = (amp * (1.0 + Math.sin(x * 0.32 + frame * 0.22))).round.to_i.clamp(0, band_h - 1)
      col = hsv((x * 7 + frame * 6) % 360)
      grid[r][x] = "{#{col}-fg}#{ch}{/}"
    end
    sine.content = (0...band_h).map { |r|
      String.build { |io| (0...w).each { |x| io << (grid[r][x] || " ") } }
    }.join('\n')

    # letters shot from the centre dot, spiralling clockwise to fill the screen
    f = frame % cycle
    letters.each_with_index do |box, i|
      destx, desty, fch = slots[i]
      lf = i * INTERVAL
      col = cx
      row = cy
      if f < lf
        box.content = "·"
        box.style.fg = (frame // 3).even? ? "#ff8080" : "#80c0ff"
      elsif f < lf + TRAVEL
        p = (f - lf) / TRAVEL.to_f
        col = (cx + (destx - cx) * p).round.to_i
        row = (cy + (desty - cy) * p).round.to_i
        box.content = GROW[(p * GROW.size).to_i.clamp(0, GROW.size - 1)]
        box.style.fg = hsv((i * 9 + frame * 9) % 360)
      else
        col = destx
        row = desty
        box.content = fch.to_s
        box.style.fg = hsv((i * 9 + frame * 6) % 360)
      end
      box.clear_last_rendered_position
      box.left = col
      box.top = row
      box.style.bg = bg_under.call(row, frame)
    end

    frame += 1
    s.render
    sleep 0.07.seconds
  end
end

s.exec
