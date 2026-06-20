# IMPRESSIVE DEMO: a "cracktro" — the animated intro old-school crackers bolted
# onto pirated games. All the classic ingredients, in the standard 80x15 window:
#
#   * a big color-cycling logo (BigText),
#   * copper / raster bars (full-width 24-bit color bands scrolling),
#   * flashing greetings, and
#   * the obligatory left-scrolling message at the bottom.

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

# Copper bars: two full-width bands of color rows that scroll.
bar_rows = [0, 1, h - 5, h - 4, h - 3]
bars = {} of Int32 => Widget::Box
bar_rows.each do |row|
  bars[row] = Widget::Box.new(parent: s, top: row, left: 0, width: "100%", height: 1,
    style: Style.new(bg: "#000000"))
end

# Big color-cycling logo.
logo = Widget::BigText.new \
  parent: s, top: 2, left: "center", height: 6,
  content: "CRYSTERM", style: Style.new(fg: "#ffffff")

# Flashing tagline between logo and bottom band.
tag1 = Widget::Box.new \
  parent: s, top: 9, left: 0, width: "100%", height: 1, align: :hcenter,
  content: "* CRACKED BY THE CRYSTERM CREW *",
  style: Style.new(fg: "yellow", bg: "black")

# The scroller.
scroller = Widget::Box.new \
  parent: s, top: h - 1, left: 0, width: "100%", height: 1,
  content: "", style: Style.new(fg: "#00ffff", bg: "#101010")

MSG = ("WELCOME TO THE CRYSTERM CRACKTRO !!!      " +
       "ANOTHER FINE RELEASE COMPILED STRAIGHT FROM CRYSTAL SOURCE ...      " +
       "GREETINGS FLY OUT TO:  BLESSED * BLESSED-CONTRIB * QT * NCURSES (R.I.P.) * EVERY CRYSTAL CODER * THE WHOLE DEMOSCENE ...      " +
       "REMEMBER - REAL ONES NEVER REMOVE THE INTRO !      " +
       "...... WRAPPING AROUND ......        ")
SCROLL = MSG + MSG

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

frame = 0
spawn do
  loop do
    bars.each do |row, box|
      box.style.bg = hsv(((row * 24) + frame * 9) % 360)
    end
    logo.style.fg = hsv((frame * 10) % 360)
    tag1.style.fg = (frame // 4).even? ? "#ffffff" : "#ff2020"
    off = frame % MSG.size
    scroller.content = SCROLL[off, w]
    scroller.style.fg = hsv((frame * 14) % 360)
    frame += 1
    s.render
    sleep 0.07.seconds
  end
end

s.exec
