# A "quicktro" — the *fast* twin of `cracktro.cr`. Pixel-for-pixel the same
# animation (copper bars, line scroller, flashing greet, sine-wave rainbow
# scroller, and letters spiralling out of the centre to fill the screen), but
# produced the fastest way the framework allows.
#
# `cracktro.cr` is deliberately a widget stress test: it spawns one `Box` per
# screen cell for the spiral (≈ w·h widgets — ~1200 on an 80×15), plus a
# `CopperBar`/`Marquee`/`SineScroller`/`Fps`, and lets the compositor place and
# paint every one of them each frame. The per-widget machinery (style objects,
# `%`-relative position resolution, content tag-parsing, per-widget composite
# and damage bookkeeping) is exactly the cost being stressed.
#
# `quicktro.cr` throws all of that away. It is ONE widget whose `#render` writes
# the finished cells straight into the window buffer with `fill_region` — the
# same primitive the effect widgets bottom out to — computing each cell's glyph
# and packed `0xRRGGBB` attr by hand. No per-cell widgets, no content strings,
# no tag parsing. Only the `Fps` overlay is kept as a real widget (it reads the
# window's genuine render/draw/flush stats, so it honestly reports the speedup).
#
# Why still a widget, and not a bare `window.draw` loop? Because Crysterm's
# headless capture (the `.dump`/`.png`/`.apng` goldens) is driven by the
# window's own `_render` → `Event::Rendered` cycle. Painting inside a child's
# `#render` — during the compositor's pass, after its buffer clear — keeps the
# demo fully capturable, exactly like `cracktro.cr`, while collapsing ~1200
# widgets into one. (A pure `window.fill_region … ; window.draw` loop with no
# widgets would be marginally faster still, but `_render` never runs, so nothing
# could snapshot the frames — see `nitro.cr` for that variant.)

require "../../src/crysterm"

include Crysterm

MSG = ("WELCOME TO THE CRYSTERM CRACKTRO !!!   GREETINGS TO:  BLESSED * " +
       "BLESSED-CONTRIB * QT * NCURSES (R.I.P.) * EVERY CRYSTAL CODER * " +
       "THE WHOLE DEMOSCENE ...   REAL ONES NEVER REMOVE THE INTRO !   ......   ")

GREET = "* CRACKED BY THE CRYSTERM CREW *"

# Top row pattern and the fake letter-growth ramp, identical to `cracktro.cr`.
PATTERN  = "CRYSTERM "
GROW     = ['.', '·', ':', '*', 'o', 'O', '0', '@']
INTERVAL =  1 # frames between successive letter launches
TRAVEL   = 12 # frames a letter spends in flight
HOLD     = 28 # frames the finished spiral is held before re-firing

# Copper / raster bars live on rows 1 and 3 (rows 0/2 carry the fps and the
# line scroller). Bar `i` is staggered `i*26°` around the color wheel and every
# bar advances `9°` per frame — the exact hue math `Widget::Effect::CopperBar`
# uses, replicated here so a landed letter can adopt the bar's background.
COPPER_ROWS = [1, 3]

BLACK = 0x000000

# The whole scene, painted by hand into the window's cell buffer. Everything
# `cracktro.cr` builds from separate widgets is reproduced here with the same
# per-frame math, but written straight to cells via `window.fill_region` — the
# fast path the effect widgets themselves use internally.
class Scene < Widget::Box
  # Frame counter, advanced by the master clock below. `#render` is a pure
  # function of it (state and paint are split, exactly as the real effect
  # widgets split `#step` from `#render`).
  property frame : Int64 = 0_i64

  # Geometry, (re)derived from the window size — cached and rebuilt only on a
  # resize, so a steady-state frame does no allocation.
  @w = 0
  @h = 0
  @cx = 0
  @cy = 0
  @cycle = 1
  # Spiral destinations: {x, y, landed-glyph} for every cell, in fill order.
  @slots = [] of Tuple(Int32, Int32, Char)
  # Background color per row this frame (copper hue on the bar rows, else black),
  # so a flying letter adopts what it flies over without a per-cell recompute.
  @row_bg = [] of Int32
  # `MSG` decomposed once; `String#[]` is O(n) for non-ASCII, and the scrollers
  # index it per column per frame.
  @chars : Array(Char) = MSG.chars

  # Clockwise spiral over every cell from the top-left corner (top row L→R, down
  # the right border, bottom row R→L, up the left border, then inward). Each
  # successive cell is where one shot-out letter lands. Identical to `cracktro`.
  private def spiral_order(w, h) : Array(Tuple(Int32, Int32))
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

  # Rebuild size-dependent state; cheap no-op unless the terminal resized.
  private def ensure_geometry(w, h)
    return if w == @w && h == @h
    @w, @h = w, h
    @cx, @cy = w // 2, h // 2
    @row_bg = Array.new(h, BLACK)
    letters = PATTERN.chars.reject { |c| c == ' ' }
    @slots = spiral_order(w, h).map_with_index do |(x, y), i|
      {x, y, letters[i % letters.size]}
    end
    @cycle = @slots.size * INTERVAL + TRAVEL + HOLD
  end

  # Pack a foreground/background pair (native `0xRRGGBB`, or -1 = terminal
  # default) into a cell attr. No flags — the cracktro scene uses none.
  private def attr(fg, bg) : Int64
    Attr.pack(0, Attr.pack_color(fg), Attr.pack_color(bg))
  end

  def render(with_children = true)
    # Establish `@lpos`/background via the normal box path (the compositor has
    # already cleared the buffer to the default cell, so this writes nothing new
    # on a full-screen default-styled box), then overpaint the scene.
    super

    win = window
    w = win.awidth
    h = win.aheight
    return if w <= 0 || h <= 0
    ensure_geometry w, h

    fr = @frame

    # Copper rows: one solid hue-cycled band each, staggered around the wheel.
    COPPER_ROWS.each_with_index do |row, idx|
      next unless row < h
      bg = Colors.hsv_i((idx * 26 + fr * 9) % 360)
      win.fill_region attr(-1, bg), ' ', 0, w, row, row + 1
    end

    # This frame's per-row letter background (copper hue on bar rows, else black).
    (0...h).each do |r|
      ci = COPPER_ROWS.index(r)
      @row_bg[r] = ci ? Colors.hsv_i((ci * 26 + fr * 9) % 360) : BLACK
    end

    n = @chars.size

    # Row 2: right-to-left rainbow line scroller (a `Marquee`, by hand). Each
    # column shows MSG[(fr + x) mod n]; the loop wraps on MSG's own length so
    # its trailing spaces form the seamless gap.
    if 2 < h
      win.fill_region attr(-1, BLACK), ' ', 0, w, 2, 3
      (0...w).each do |x|
        ch = @chars[(fr + x) % n]
        next if ch == ' '
        win.fill_region attr(Colors.hsv_i((x * 7 + fr * 8) % 360), BLACK), ch, x, x + 1, 2, 3
      end
    end

    # Row 4: the flashing centered greet.
    if 4 < h
      win.fill_region attr(-1, BLACK), ' ', 0, w, 4, 5
      fg = (fr // 4).even? ? 0xffff00 : 0xff3030
      gx = {(w - GREET.size) // 2, 0}.max
      GREET.chars.each_with_index do |ch, i|
        next if ch == ' '
        win.fill_region attr(fg, BLACK), ch, gx + i, gx + i + 1, 4, 5
      end
    end

    # Rows 5..: sine-wave rainbow scroller (a `SineScroller`, by hand). Same
    # horizontal loop as the marquee, each glyph placed on the row given by
    # sin(x·0.32 + fr·0.22) and tinted its own cycling hue.
    sine_top = 5
    if sine_top < h
      win.fill_region attr(-1, BLACK), ' ', 0, w, sine_top, h
      sh = h - sine_top
      amp = (sh - 1) / 2.0
      (0...w).each do |x|
        ch = @chars[(fr + x) % n]
        next if ch == ' '
        r = (amp * (1.0 + Math.sin(x * 0.32 + fr * 0.22))).round.to_i.clamp(0, sh - 1)
        win.fill_region attr(Colors.hsv_i((x * 7 + fr * 6) % 360), BLACK), ch, x, x + 1, sine_top + r, sine_top + r + 1
      end
    end

    # Letters shot from the centre dot, spiralling clockwise to fill the screen.
    # Painted last (on top of the scene); before launch they stack on the centre
    # cell, so a later letter overpaints an earlier one there — the same result
    # the widget z-order produced in `cracktro.cr`.
    f = (fr % @cycle).to_i
    @slots.each_with_index do |slot, i|
      destx, desty, fch = slot
      lf = i * INTERVAL
      col, row = @cx, @cy
      if f < lf
        ch = '·'
        fg = (fr // 3).even? ? 0xff8080 : 0x80c0ff
      elsif f < lf + TRAVEL
        p = (f - lf) / TRAVEL.to_f
        col = (@cx + (destx - @cx) * p).round.to_i
        row = (@cy + (desty - @cy) * p).round.to_i
        ch = GROW[(p * GROW.size).to_i.clamp(0, GROW.size - 1)]
        fg = Colors.hsv_i((i * 9 + fr * 9) % 360)
      else
        col, row = destx, desty
        ch = fch
        fg = Colors.hsv_i((i * 9 + fr * 6) % 360)
      end
      win.fill_region attr(fg, @row_bg[row]), ch, col, col + 1, row, row + 1
    end
  end
end

# Full-screen animation: every cell changes every frame, so damage tracking
# only adds bookkeeping — `OptimizationFlag::None` (full re-composite) is faster
# and correct here, exactly as in `cracktro.cr`.
s = Window.new title: "CRYSTERM quicktro", optimization: OptimizationFlag::None

scene = Scene.new parent: s, top: 0, left: 0, width: "100%", height: "100%"

# Live performance overlay — kept as a real widget so it reports the window's
# genuine per-frame figures. Added last, so it paints on top of the scene.
Widget::Fps.new \
  parent: s, top: 0, left: 0,
  format: " FPS %s (avg %s)  render %s  draw %s  flush %s ",
  args: %i[fps fps_avg render draw flush],
  style: Style.new(fg: "white", bg: "black")

# One master clock advances the frame; the render right after it repaints the
# whole scene. (State-advance here, painting in `#render` — the same split the
# effect widgets use.)
s.every(0.07.seconds) { scene.frame += 1 }

s.exec
