require "../../../src/crysterm"

# Commando
# ========
#
# A terminal homage to *Commando* (Capcom, 1985; the Commodore 64 conversion
# published by Elite in 1985 — see https://www.lemon64.com/game/commando).
#
# You are Super Joe, dropped alone behind enemy lines. The battlefield scrolls
# vertically upward as you advance on foot; the screen never scrolls back, so
# there is no retreat. Gun down or run past the endless enemy soldiers, use the
# terrain for cover, lob grenades over sandbag nests, cross the river at the
# bridge and fight through to the enemy fortress gate at the top of the map.
#
# Faithful touches from the original:
#   * Vertical forced-scroll run-and-gun; the bottom of the screen is a wall.
#   * The rifle fires in the direction you are facing (8-way).
#   * Grenades are thrown *straight up* only — the C64 spacebar quirk — and are
#     the way to clear soldiers dug in behind sandbags your bullets can't pass.
#   * Trees, rocks, sandbag trenches, a river with a single bridge, walled
#     compounds and a final fortress with its heavily-defended gate.
#   * Contact with a soldier costs a life; you get a moment of invulnerability.
#
# Controls:
#   Arrow keys / W A S D   move (and aim the rifle)
#   Space or F             fire rifle (in the direction you face)
#   G or J                 throw a grenade (straight up)
#   P                      pause
#   R                      restart
#   Q / Esc / Ctrl-Q       quit
#
# The battlefield is painted by writing packed cells straight into the window
# buffer (the fast `fill_region` path, as in `tests/misc/quicktro.cr`) — no
# per-frame tag strings to parse. See `Commando#draw_scene`.
#
# `Field` is the play-window widget: a bordered box whose `#render` runs during
# the compositor's pass (after its buffer clear), then hands off to the game to
# overpaint the scene. A `painter` proc is used so this can be defined before
# `Commando`.
class Field < Crysterm::Widget::Box
  property painter : (Field ->)? = nil

  def render(with_children = true)
    super
    painter.try &.call(self)
  end
end

# Everything is drawn by hand into the window's cell buffer, rebuilt every frame
# from world state (see `draw_scene`).
class Commando
  include Crysterm

  # ---- World / view geometry -------------------------------------------------

  # The play window is a fixed WORLD_W columns wide; the world is WORLD_H rows
  # tall and only ever scrolls vertically, so no horizontal camera is needed.
  WORLD_W =  64
  WORLD_H = 150
  FPS     =  15

  # Kept at roughly three-quarters down the screen; the camera follows upward.
  ANCHOR_FRAC = 0.72

  # ---- Palette (C64-ish battlefield) -----------------------------------------
  #
  # Scene colours are packed `0xRRGGBB` ints, not `#rrggbb` strings: the field
  # is painted by writing cells straight into the window buffer with
  # `fill_region` (the fast path `tests/misc/quicktro.cr` uses), so there are no
  # tag strings to parse. (UI text — status bar, overlays — still uses tags.)

  GRASS1    = 0x3f7a34
  DIRT_BG   = 0x7a5a34
  WATER_BG  = 0x1f486e
  WATER_FG  = 0x3f6f9e
  BRIDGE_BG = 0x6a4a2a
  BRIDGE_FG = 0x3a2a18
  SAND_BG   = 0xa68a4a
  SAND_FG   = 0x7d6636
  ROCK_BG   = 0x565660
  ROCK_FG   = 0x7a7a86
  TREE_FG   = 0x1f5a1a
  WALL_BG   = 0x41414c
  WALL_FG   = 0x63636e
  GATE_BG   = 0x241d16

  PLAYER_FG   = 0xf7f24a
  PLAYER_HURT = 0xffffff
  GRUNT_FG    = 0xe0492a
  GUNNER_FG   = 0xf0b030
  BOSS_FG     = 0xe24ad0
  PBULLET_FG  = 0xfff36b
  EBULLET_FG  = 0xff6a4a
  GRENADE_FG  = 0xd0d0d0
  PICKUP_FG   = 0x7ef07e

  EXPLOSION = {
    {'✳', 0xfff3a0}, {'✷', 0xffd24a}, {'✸', 0xff9a2a},
    {'❋', 0xff6a1a}, {'*', 0xe0641a}, {'·', 0xb0521a},
  }

  # ---- Entities --------------------------------------------------------------

  enum Kind
    Grunt  # charges the player; dies on contact
    Gunner # keeps position-ish and shoots
    Boss   # fortress defender: tough, fires a spread
  end

  # An enemy soldier. Grid position, with per-entity move/fire timers so not
  # everything ticks in lockstep.
  class Enemy
    property x : Int32
    property y : Int32
    property kind : Kind
    property hp : Int32
    property move_cd : Int32
    property fire_cd : Int32
    property alive = true

    def initialize(@x, @y, @kind)
      case @kind
      in .grunt?  then @hp = 1; @move_cd = 3; @fire_cd = 0
      in .gunner? then @hp = 1; @move_cd = 5; @fire_cd = 12
      in .boss?   then @hp = 5; @move_cd = 6; @fire_cd = 9
      end
    end
  end

  # A projectile in fractional cell-space. `friendly` bullets are the player's.
  class Bullet
    property x : Float64
    property y : Float64
    property vx : Float64
    property vy : Float64
    property friendly : Bool

    def initialize(@x, @y, @vx, @vy, @friendly)
    end
  end

  # A grenade arcs straight up a few rows, then detonates.
  class Grenade
    property x : Float64
    property y : Float64
    property vy : Float64
    property fuse : Int32

    def initialize(@x, @y, @vy, @fuse)
    end
  end

  # A short-lived blast: clears soldiers and levels sandbags/trees in radius.
  class Blast
    property x : Int32
    property y : Int32
    property radius : Int32
    property age = 0

    def initialize(@x, @y, @radius)
    end
  end

  # A dropped grenade crate.
  class Pickup
    property x : Int32
    property y : Int32
    property alive = true

    def initialize(@x, @y)
    end
  end

  # Deferred enemy placement: activated (spawned) as its row nears the top of
  # the view, so soldiers march in from ahead instead of all existing at once.
  record SpawnPoint, x : Int32, y : Int32, kind : Kind

  enum State
    Title
    Playing
    Paused
    Dead
    Won
  end

  # ---- Mutable game state ----------------------------------------------------

  @world = [] of Array(Char)
  @spawns = [] of SpawnPoint
  @spawned = Set(Int32).new
  @enemies = [] of Enemy
  @bullets = [] of Bullet
  @grenades = [] of Grenade
  @blasts = [] of Blast
  @pickups = [] of Pickup

  @px : Int32 = WORLD_W // 2
  @py : Int32 = WORLD_H - 3
  @face_x : Int32 = 0
  @face_y : Int32 = -1 # facing up by default
  @cam_y : Int32 = 0
  @view_h : Int32 = 22

  @lives : Int32 = 3
  @grenade_count : Int32 = 4
  @score : Int32 = 0
  @invuln : Int32 = 0  # frames of post-hit invulnerability remaining
  @fire_cd : Int32 = 0 # rifle cooldown (frames)
  @gren_cd : Int32 = 0
  @frame : Int32 = 0
  @state : State = :title

  def initialize
    # Full-motion scene: every field cell can change each frame, so damage
    # tracking is pure overhead — `OptimizationFlag::None` (full re-composite) is
    # faster and correct, exactly as in `quicktro.cr`.
    @screen = Window.new title: "commando.cr", optimization: OptimizationFlag::None

    @field = Field.new \
      parent: @screen,
      top: 0,
      left: "center",
      width: WORLD_W + 2,
      height: "100%-1",
      style: Style.new(fg: "white", bg: "#101410", border: true)
    @field.style.border = Border.new(BorderType::Line, fg: "#6a6a72")
    @field.painter = ->(f : Field) { draw_scene f }

    @status = Widget::StatusBar.new \
      parent: @screen,
      bottom: 0,
      left: 0,
      width: "100%",
      height: 1,
      parse_tags: true,
      style: Style.new(fg: "white", bg: "#20241c")

    # Overlays are siblings of the field (children of the screen), created after
    # it, so they composite ON TOP of the hand-painted scene instead of being
    # overpainted by it.
    #
    # Centered card for the title / pause / game-over / victory screens.
    @overlay = Widget::Box.new \
      parent: @screen,
      top: "center",
      left: "center",
      width: 46,
      height: 11,
      parse_tags: true,
      align: "center",
      style: Style.new(fg: "white", bg: "#14180f", border: true, bold: true)
    @overlay.style.border = Border.new(BorderType::Double, fg: "#c8b048")

    # A slim top banner shown during the attract-mode demo, so the live
    # gameplay stays visible below it.
    @banner = Widget::Box.new \
      parent: @screen,
      top: 1,
      left: "center",
      width: 48,
      height: 6,
      parse_tags: true,
      align: "center",
      style: Style.new(fg: "white", bg: "#14180f", border: true, bold: true)
    @banner.style.border = Border.new(BorderType::Double, fg: "#c8b048")
    @banner.hide

    @screen.on(Event::KeyPress) { |e| on_key e }
    @screen.on(Event::Resize) { @screen.render }
  end

  def run
    show_title
    # State-advance here; the repaint happens in `Field#render` (triggered by
    # the `render` that `every` runs after this block). Painting writes cells
    # straight to the buffer, so a frame stays well under the interval and the
    # FrameClock sleeps normally — no busy-loop, input stays responsive.
    @screen.every((1.0 / FPS).seconds) { tick }
    @screen.exec
  end

  # ---- Level design ----------------------------------------------------------

  # Draw the fixed level into @world (top row 0 = fortress/goal, bottom row =
  # player start) and register enemy spawn points. Grass is the default tile.
  #
  # Tiles: '.' grass  'd' dirt  '#' rock(solid)  's' sandbag(solid cover)
  #        't' tree(solid)  'w' water(solid to player, bullets pass)
  #        'b' bridge(walk)  'W' fortress wall(solid)  'G' gate(walk goal)
  private def build_level
    @world = Array.new(WORLD_H) { Array.new(WORLD_W, '.') }

    set = ->(x : Int32, y : Int32, c : Char) do
      @world[y][x] = c if y >= 0 && y < WORLD_H && x >= 0 && x < WORLD_W
    end
    hline = ->(x0 : Int32, x1 : Int32, y : Int32, c : Char) do
      (x0..x1).each { |x| set.call(x, y, c) }
    end
    vline = ->(x : Int32, y0 : Int32, y1 : Int32, c : Char) do
      (y0..y1).each { |y| set.call(x, y, c) }
    end
    rect = ->(x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32, c : Char) do
      (y0..y1).each { |y| (x0..x1).each { |x| set.call(x, y, c) } }
    end

    cx = WORLD_W // 2

    # --- Fortress and gate (top, the goal) ---
    # Solid wall band across the whole width with a 4-wide gate opening.
    rect.call(0, 1, WORLD_W - 1, 3, 'W')
    rect.call(cx - 2, 1, cx + 1, 3, 'G')
    hline.call(0, WORLD_W - 1, 0, 'G') # interior victory strip
    # Battlements flanking the gate with the last-ditch bosses.
    @spawns << SpawnPoint.new(cx - 5, 5, :boss)
    @spawns << SpawnPoint.new(cx + 5, 5, :boss)
    @spawns << SpawnPoint.new(cx, 6, :gunner)

    # --- Fortress approach: two rock towers and a gunner nest ---
    rect.call(6, 5, 11, 10, '#')
    rect.call(WORLD_W - 12, 5, WORLD_W - 7, 10, '#')
    hline.call(cx - 6, cx + 5, 12, 's')
    @spawns << SpawnPoint.new(cx - 4, 11, :gunner)
    @spawns << SpawnPoint.new(cx + 3, 11, :gunner)
    @spawns << SpawnPoint.new(cx, 14, :grunt)
    @spawns << SpawnPoint.new(cx - 8, 15, :grunt)
    @spawns << SpawnPoint.new(cx + 8, 15, :grunt)

    # --- Trench line 2 (sandbag wall with two gaps + gunners) ---
    hline.call(4, WORLD_W - 5, 21, 's')
    rect.call(cx - 3, 21, cx - 2, 21, '.') # gap
    rect.call(18, 21, 19, 21, '.')         # gap
    (0..3).each { |i| @spawns << SpawnPoint.new(10 + i * 14, 20, :gunner) }
    @spawns << SpawnPoint.new(cx, 26, :grunt)
    @spawns << SpawnPoint.new(cx - 10, 28, :grunt)
    @spawns << SpawnPoint.new(cx + 10, 28, :grunt)
    @pickups << Pickup.new(cx, 24)

    # --- Walled compound: rock corridors with soldiers inside ---
    vline.call(14, 32, 44, '#')
    vline.call(WORLD_W - 15, 32, 44, '#')
    hline.call(14, 26, 32, '#')
    hline.call(WORLD_W - 27, WORLD_W - 15, 32, '#')
    hline.call(14, 24, 44, '#')
    hline.call(WORLD_W - 25, WORLD_W - 15, 44, '#')
    rect.call(28, 36, 30, 40, 't') # interior copse
    rect.call(WORLD_W - 31, 36, WORLD_W - 29, 40, 't')
    @spawns << SpawnPoint.new(cx, 34, :gunner)
    @spawns << SpawnPoint.new(20, 38, :grunt)
    @spawns << SpawnPoint.new(WORLD_W - 21, 38, :grunt)
    @spawns << SpawnPoint.new(cx, 42, :gunner)
    @spawns << SpawnPoint.new(cx - 12, 43, :grunt)
    @spawns << SpawnPoint.new(cx + 12, 43, :grunt)

    # --- The river: full-width water with a single bridge ---
    rect.call(0, 58, WORLD_W - 1, 61, 'w')
    rect.call(cx - 2, 57, cx + 1, 62, 'b') # bridge planks
    hline.call(cx - 6, cx + 5, 63, 's')    # sandbag chokepoint guarding it
    rect.call(cx - 2, 63, cx + 1, 63, '.') # bridge mouth left open
    @spawns << SpawnPoint.new(cx - 4, 56, :gunner)
    @spawns << SpawnPoint.new(cx + 3, 56, :gunner)
    @spawns << SpawnPoint.new(cx, 64, :grunt)
    @pickups << Pickup.new(cx - 8, 65)

    # --- Open patrol field with scattered trees and roving grunts ---
    scatter_trees(70, 86, 90)
    @spawns << SpawnPoint.new(12, 72, :grunt)
    @spawns << SpawnPoint.new(WORLD_W - 12, 74, :grunt)
    @spawns << SpawnPoint.new(cx, 76, :gunner)
    @spawns << SpawnPoint.new(20, 80, :grunt)
    @spawns << SpawnPoint.new(WORLD_W - 20, 82, :grunt)
    @spawns << SpawnPoint.new(cx - 6, 84, :grunt)
    @spawns << SpawnPoint.new(cx + 6, 84, :grunt)

    # --- Trench line 1 (first contact) ---
    hline.call(6, WORLD_W - 7, 96, 's')
    rect.call(cx - 1, 96, cx, 96, '.') # gap
    @spawns << SpawnPoint.new(16, 95, :gunner)
    @spawns << SpawnPoint.new(cx, 95, :gunner)
    @spawns << SpawnPoint.new(WORLD_W - 16, 95, :gunner)
    @spawns << SpawnPoint.new(cx - 8, 100, :grunt)
    @spawns << SpawnPoint.new(cx + 8, 100, :grunt)

    # --- Treeline with gaps before the trench ---
    scatter_trees(106, 114, 140)
    hline.call(0, 24, 110, 't')
    hline.call(WORLD_W - 25, WORLD_W - 1, 110, 't')
    @spawns << SpawnPoint.new(cx, 108, :grunt)

    # --- Landing zone: a dirt clearing where Super Joe starts ---
    rect.call(cx - 8, 120, cx + 7, 149, 'd')
    (120..149).each do |y| # feather the dirt edges into grass
      set.call(cx - 9, y, '.') if y.even?
      set.call(cx + 8, y, '.') if y.even?
    end
  end

  # Sprinkle trees between rows y0..y1 using position-hashed noise so the
  # placement is fixed (no shimmering) and leaves the center lane mostly clear.
  private def scatter_trees(y0, y1, density)
    (y0..y1).each do |y|
      (2...WORLD_W - 2).each do |x|
        next if (x - WORLD_W // 2).abs < 4 # keep a central path open
        @world[y][x] = 't' if noise(x, y) % 100 < (100 - density)
      end
    end
  end

  # ---- Game flow -------------------------------------------------------------

  # Rebuild the battlefield and reset the soldier — used both to deploy for real
  # and to (re)start the attract-mode demo. Leaves @state and overlays alone.
  private def setup_world
    @enemies.clear
    @bullets.clear
    @grenades.clear
    @blasts.clear
    @spawned.clear
    build_level # rebuild pickups/spawns fresh

    @px = WORLD_W // 2
    @py = WORLD_H - 3
    @face_x = 0
    @face_y = -1
    @cam_y = WORLD_H - @view_h
    @lives = 3
    @grenade_count = 4
    @score = 0
    @invuln = 0
    @fire_cd = 0
    @gren_cd = 0
    @frame = 0
  end

  # Hand control to the player.
  private def deploy
    setup_world
    @state = :playing
    @banner.hide
    @overlay.hide
    render
  end

  # Show the title / attract screen. `tick` drives a self-playing demo behind
  # the banner (an arcade cabinet's attract mode); pressing a key deploys.
  private def show_title
    setup_world
    @state = :title
    @banner.content =
      "{#f7f24a-fg}C O M M A N D O{/}\n\n" \
      "arrows/WASD move · Space fire · G grenade\n" \
      "{#7ef07e-fg}Press ENTER / SPACE to deploy{/}"
    @overlay.hide
    @banner.show
    render
  end

  private def game_over(won)
    @state = won ? State::Won : State::Dead
    title = won ? "{#7ef07e-fg}MISSION COMPLETE{/}" : "{#ff6a4a-fg}K.I.A.{/}"
    line = won ? "You breached the fortress gate!" : "Super Joe has fallen."
    @overlay.content =
      "#{title}\n\n" \
      "#{line}\n\n" \
      "Final score: {#f7f24a-fg}#{@score}{/}\n\n\n" \
      "{#7ef07e-fg}Press R to deploy again — Q to quit{/}"
    @banner.hide
    @overlay.show
    @screen.render
  end

  # ---- Input -----------------------------------------------------------------

  private def on_key(e)
    case
    when e.char == 'q', e.key == Tput::Key::Escape, e.key == Tput::Key::CtrlQ
      @screen.destroy
      exit 0
    when @state.title?
      deploy if e.key == Tput::Key::Enter || e.key == Tput::Key::Space || e.char == ' '
    when @state.dead? || @state.won?
      deploy if e.char == 'r'
    when @state.paused?
      if e.char == 'p'
        @state = :playing
        @overlay.hide
        @screen.render
      end
    when @state.playing?
      handle_play_key e
    end
  end

  private def handle_play_key(e)
    case
    when e.key == Tput::Key::Up, e.char == 'w'    then move(0, -1)
    when e.key == Tput::Key::Down, e.char == 's'  then move(0, 1)
    when e.key == Tput::Key::Left, e.char == 'a'  then move(-1, 0)
    when e.key == Tput::Key::Right, e.char == 'd' then move(1, 0)
    when e.char == ' ', e.char == 'f'             then fire
    when e.char == 'g', e.char == 'j'             then throw_grenade
    when e.char == 'p'
      @state = :paused
      @overlay.content = "\n{#f7f24a-fg}— PAUSED —{/}\n\n\nPress P to resume."
      @overlay.show
      @screen.render
    end
  end

  # Try to step the player one cell, always turning the rifle to face `dx,dy`
  # even when the way is blocked. Returns whether the move happened.
  private def step_player(dx, dy) : Bool
    @face_x, @face_y = dx, dy
    nx, ny = @px + dx, @py + dy
    return false if nx < 0 || nx >= WORLD_W || ny < 0 || ny >= WORLD_H
    return false if solid?(nx, ny)
    # The bottom of the screen is a wall; you cannot fall back off-camera.
    return false if ny > @cam_y + @view_h - 1
    @px, @py = nx, ny
    check_pickups
    true
  end

  # Interactive move: step and repaint promptly so movement feels responsive
  # between the fixed ticks.
  private def move(dx, dy)
    step_player dx, dy
    render
  end

  # Attract-mode brain: push toward the fortress, sidestep to line up on the
  # nearest soldier, keep the rifle firing upward, and grenade over sandbags.
  private def autopilot
    target = @enemies.select(&.alive).min_by? { |e| (e.y - @py).abs + (e.x - @px).abs }
    stepped = false
    if target && @frame % 2 == 0 && (target.y - @py).abs < 10
      stepped = step_player(target.x <=> @px, 0) if target.x != @px
    end
    step_player(0, -1) if !stepped && @frame % 2 == 0
    @face_x, @face_y = 0, -1
    fire if @frame % 3 == 0
    if @grenade_count > 0 && (1..3).any? { |d| tile_at(@px, @py - d) == 's' }
      throw_grenade
    end
  end

  private def fire
    return if @fire_cd > 0
    @fire_cd = 2
    dx = @face_x.to_f
    dy = @face_y.to_f
    dx = 0.0 if dx == 0 && dy == 0 # safety; default straight up
    dy = -1.0 if dx == 0 && dy == 0
    # Normalize so diagonals aren't faster than straight shots.
    mag = Math.sqrt(dx * dx + dy * dy)
    speed = 2.2
    @bullets << Bullet.new(@px.to_f, @py.to_f, dx / mag * speed, dy / mag * speed, true)
  end

  # Grenades only ever go straight up — the original's spacebar quirk — which is
  # the sole way past soldiers dug in behind sandbag walls bullets can't cross.
  private def throw_grenade
    return if @gren_cd > 0 || @grenade_count <= 0
    @grenade_count -= 1
    @gren_cd = 6
    @grenades << Grenade.new(@px.to_f, (@py - 1).to_f, -0.9, 7)
  end

  # ---- Simulation ------------------------------------------------------------

  private def tick
    # Both live play and the attract-mode demo advance the simulation.
    return unless @state.playing? || @state.title?
    @frame += 1
    @fire_cd -= 1 if @fire_cd > 0
    @gren_cd -= 1 if @gren_cd > 0
    @invuln -= 1 if @invuln > 0

    autopilot if @state.title?

    update_camera
    activate_spawns
    step_enemies
    step_bullets
    step_grenades
    step_blasts
    cull

    # Loop the attract demo when Joe falls or breaks through, without ending it.
    setup_world if @state.title? && (@lives < 0 || @py <= 1)

    # Refresh the status bar (state phase); the repaint is `Field#render`, run
    # by `every` right after this tick.
    render_status
  end

  private def update_camera
    anchor = (@view_h * ANCHOR_FRAC).to_i
    target = (@py - anchor).clamp(0, WORLD_H - @view_h)
    # Forward-only scroll: the camera climbs with the player but never descends.
    @cam_y = target if target < @cam_y
    @cam_y = @cam_y.clamp(0, WORLD_H - @view_h)
  end

  # Bring soldiers onto the field as their row reaches the top of the view.
  private def activate_spawns
    @spawns.each_with_index do |sp, i|
      next if @spawned.includes?(i)
      next unless @cam_y <= sp.y + 1 && sp.y <= @cam_y + @view_h
      @spawned << i
      @enemies << Enemy.new(sp.x, sp.y, sp.kind)
    end
  end

  private def step_enemies
    @enemies.each do |en|
      next unless en.alive

      # Move toward the player on the frames this soldier is due to step.
      if @frame % en.move_cd == 0
        step_enemy_toward_player en
      end

      # Contact damage (and grunts detonate on contact).
      if en.x == @px && en.y == @py
        hurt_player
        en.alive = false if en.kind.grunt?
      end

      # Gunners and bosses shoot on their fire cadence when on-screen.
      if (en.kind.gunner? || en.kind.boss?) && en.fire_cd > 0
        if @frame % en.fire_cd == 0 && on_screen?(en.x, en.y)
          enemy_fire en
        end
      end
    end
  end

  private def step_enemy_toward_player(en)
    dx = @px - en.x
    dy = @py - en.y
    # Prefer the axis with the greater distance, fall back to the other if the
    # step is blocked, so soldiers file around walls instead of jamming.
    prim = dx.abs > dy.abs ? {dx <=> 0, 0} : {0, dy <=> 0}
    seco = dx.abs > dy.abs ? {0, dy <=> 0} : {dx <=> 0, 0}
    [prim, seco].each do |(sx, sy)|
      next if sx == 0 && sy == 0
      nx, ny = en.x + sx, en.y + sy
      next if solid?(nx, ny) || enemy_at?(nx, ny)
      en.x, en.y = nx, ny
      break
    end
  end

  private def enemy_fire(en)
    dx = (@px - en.x).to_f
    dy = (@py - en.y).to_f
    mag = Math.sqrt(dx * dx + dy * dy)
    return if mag < 0.5
    speed = 0.85
    ux, uy = dx / mag, dy / mag
    if en.kind.boss?
      # A three-round spread.
      [-0.3, 0.0, 0.3].each do |a|
        rx = ux * Math.cos(a) - uy * Math.sin(a)
        ry = ux * Math.sin(a) + uy * Math.cos(a)
        @bullets << Bullet.new(en.x.to_f, en.y.to_f, rx * speed, ry * speed, false)
      end
    else
      @bullets << Bullet.new(en.x.to_f, en.y.to_f, ux * speed, uy * speed, false)
    end
  end

  # Advance bullets in small substeps so fast rounds don't tunnel through walls
  # or soldiers.
  private def step_bullets
    @bullets.each do |b|
      steps = 4
      sx = b.vx / steps
      sy = b.vy / steps
      dead = false
      steps.times do
        b.x += sx
        b.y += sy
        cx = b.x.round.to_i
        cy = b.y.round.to_i
        if cx < 0 || cx >= WORLD_W || cy < 0 || cy >= WORLD_H
          dead = true
          break
        end
        if blocks_bullet?(cx, cy)
          dead = true
          break
        end
        if b.friendly
          if en = enemy_at(cx, cy)
            hit_enemy en
            dead = true
            break
          end
        else
          if cx == @px && cy == @py
            hurt_player
            dead = true
            break
          end
        end
      end
      b.vx = Float64::NAN if dead # mark for cull
    end
    @bullets.reject! { |b| b.vx.nan? }
  end

  private def step_grenades
    @grenades.each do |g|
      g.y += g.vy
      g.fuse -= 1
      if g.fuse <= 0
        @blasts << Blast.new(g.x.round.to_i, g.y.round.to_i, 4)
        detonate(g.x.round.to_i, g.y.round.to_i, 4)
        g.fuse = -999 # mark for cull
      end
    end
    @grenades.reject! { |g| g.fuse == -999 }
  end

  private def step_blasts
    @blasts.each { |bl| bl.age += 1 }
    @blasts.reject! { |bl| bl.age >= EXPLOSION.size }
  end

  # A grenade blast: kill soldiers and flatten sandbags/trees within radius.
  private def detonate(cx, cy, radius)
    @enemies.each do |en|
      next unless en.alive
      if (en.x - cx).abs + (en.y - cy).abs <= radius
        en.hp = 0
        hit_enemy en
      end
    end
    (-radius..radius).each do |dy|
      (-radius..radius).each do |dx|
        next if dx.abs + dy.abs > radius
        x, y = cx + dx, cy + dy
        next if x < 0 || x >= WORLD_W || y < 0 || y >= WORLD_H
        t = @world[y][x]
        @world[y][x] = '.' if t == 's' || t == 't'
      end
    end
  end

  private def hit_enemy(en)
    en.hp -= 1
    return if en.hp > 0
    en.alive = false
    @score += case en.kind
              in .grunt?  then 100
              in .gunner? then 200
              in .boss?   then 500
              end
  end

  private def hurt_player
    return if @invuln > 0
    @lives -= 1
    @invuln = (FPS * 1.3).to_i # ~1.3s of mercy invulnerability
    # In attract mode the demo simply restarts (handled in `tick`).
    game_over false if @lives < 0 && @state.playing?
  end

  private def check_pickups
    @pickups.each do |p|
      next unless p.alive
      if p.x == @px && p.y == @py
        p.alive = false
        @grenade_count += 3
      end
    end
    # Reaching the fortress interior wins (attract mode loops instead).
    game_over true if @py <= 1 && @state.playing?
  end

  # Drop dead soldiers, spent pickups, and enemies left far behind the scroll.
  private def cull
    @enemies.reject! { |en| !en.alive || en.y > @cam_y + @view_h + 6 }
    @pickups.reject! { |p| !p.alive }
    check_pickups if @state.playing?
  end

  # ---- Terrain queries -------------------------------------------------------

  private def tile_at(x, y) : Char
    return 'W' if x < 0 || x >= WORLD_W || y < 0 || y >= WORLD_H
    @world[y][x]
  end

  private def solid?(x, y) : Bool
    case tile_at(x, y)
    when '#', 's', 't', 'W', 'w' then true
    else                              false
    end
  end

  private def blocks_bullet?(x, y) : Bool
    case tile_at(x, y)
    when '#', 's', 't', 'W' then true
    else                         false # water and bridges let rounds pass
    end
  end

  private def on_screen?(x, y) : Bool
    y >= @cam_y && y < @cam_y + @view_h
  end

  private def enemy_at(x, y) : Enemy?
    @enemies.find { |en| en.alive && en.x == x && en.y == y }
  end

  private def enemy_at?(x, y) : Bool
    !enemy_at(x, y).nil?
  end

  # Deterministic position hash for stable terrain texture.
  private def noise(x, y) : Int32
    ((x &* 73856093) ^ (y &* 19349663)).abs % 1_000_000
  end

  # ---- Rendering -------------------------------------------------------------

  # Pack a foreground/background (`0xRRGGBB`, or -1 = terminal default) plus an
  # optional bold flag into a cell attr word for `fill_region`.
  private def cell(fg : Int32, bg : Int32, bold : Bool) : Int64
    Attr.pack(bold ? Attr::BOLD : 0, Attr.pack_color(fg), Attr.pack_color(bg))
  end

  # Paint the whole scene by writing packed cells straight into the window
  # buffer (the fast path from `quicktro.cr`) — no content strings, no tag
  # parsing. Runs inside `Field#render`, after the box has cleared/bordered its
  # region, so it only overpaints the field's interior.
  private def draw_scene(f : Field)
    win = f.window
    ox = f.aleft(true) + f.ileft
    oy = f.atop(true) + f.itop
    ih = f.aheight - f.itop - f.ibottom
    iw = f.awidth - f.ileft - f.iright
    @view_h = ih
    return if ih <= 0
    view_w = {iw, WORLD_W}.min
    return if view_w <= 0

    # 1) Terrain — coalesce horizontal runs of an identical cell into one
    # `fill_region`, so a whole grass/water span is a single write.
    ih.times do |sy|
      wy = @cam_y + sy
      sx = 0
      while sx < view_w
        g, fgc, bgc = terrain_cell(sx, wy)
        run = sx + 1
        while run < view_w
          ng, nf, nb = terrain_cell(run, wy)
          break unless ng == g && nf == fgc && nb == bgc
          run += 1
        end
        win.fill_region cell(fgc, bgc, false), g, ox + sx, ox + run, oy + sy, oy + sy + 1
        sx = run
      end
    end

    # A sprite cell keeps the terrain background underneath it.
    put = ->(wx : Int32, wy : Int32, g : Char, fgc : Int32, bold : Bool) do
      sx = wx
      sy = wy - @cam_y
      if sx >= 0 && sx < view_w && sy >= 0 && sy < ih
        _g, _f, tbg = terrain_cell(sx, @cam_y + sy)
        win.fill_region cell(fgc, tbg, bold), g, ox + sx, ox + sx + 1, oy + sy, oy + sy + 1
      end
    end

    # 2) Pickups.
    @pickups.each do |p|
      next unless p.alive
      put.call(p.x, p.y, '◘', PICKUP_FG, true)
    end

    # 3) Enemies.
    @enemies.each do |en|
      next unless en.alive
      g, fgc = case en.kind
               in .grunt?  then {'☹', GRUNT_FG}
               in .gunner? then {'☗', GUNNER_FG}
               in .boss?   then {'☗', BOSS_FG}
               end
      put.call(en.x, en.y, g, fgc, true)
    end

    # 4) Bullets.
    @bullets.each do |b|
      g, fgc = b.friendly ? {'•', PBULLET_FG} : {'○', EBULLET_FG}
      put.call(b.x.round.to_i, b.y.round.to_i, g, fgc, true)
    end

    # 5) Grenades.
    @grenades.each do |gr|
      put.call(gr.x.round.to_i, gr.y.round.to_i, '●', GRENADE_FG, true)
    end

    # 6) Blasts (over everything, spread across the radius as it ages).
    @blasts.each do |bl|
      g, fgc = EXPLOSION[bl.age]
      r = bl.age
      (-r..r).each do |dy|
        (-r..r).each do |dx|
          next if dx.abs + dy.abs > r || dx.abs + dy.abs < r - 1
          put.call(bl.x + dx, bl.y + dy, g, fgc, true)
        end
      end
      put.call(bl.x, bl.y, g, fgc, true)
    end

    # 7) Player (blinking while invulnerable).
    unless @state.dead? && @lives < 0
      pcol = (@invuln > 0 && @frame.even?) ? PLAYER_HURT : PLAYER_FG
      put.call(@px, @py, '☺', pcol, true)
    end
  end

  # Repaint now — for interactive callers that want immediate feedback between
  # the clock's frames. Refreshes the status bar, then composites.
  private def render
    render_status
    @screen.render
  end

  # Map one world tile to {glyph, fg, bg} (colours packed `0xRRGGBB`).
  private def terrain_cell(x, wy) : {Char, Int32, Int32}
    case tile_at(x, wy)
    when '.' then {' ', GRASS1, GRASS1}
    when 'd' then {' ', DIRT_BG, DIRT_BG}
    when 'w' then {'≈', WATER_FG, WATER_BG}
    when 'b' then {'=', BRIDGE_FG, BRIDGE_BG}
    when 's' then {'▬', SAND_FG, SAND_BG}
    when '#' then {'▓', ROCK_FG, ROCK_BG}
    when 't' then {'♣', TREE_FG, GRASS1}
    when 'W' then {'▓', WALL_FG, WALL_BG}
    when 'G' then {' ', GATE_BG, GATE_BG}
    else          {' ', GRASS1, GRASS1}
    end
  end

  private def render_status
    @status.clear_permanent
    hearts = @lives >= 0 ? "♥" * @lives : ""
    @status.add_permanent "Lives #{hearts}"
    @status.add_permanent "Grenades #{@grenade_count}"
    @status.add_permanent "Score #{sprintf("%06d", @score)}"
    # Progress toward the gate (top of the map).
    pct = 100 - (@py * 100 // WORLD_H)
    @status.add_permanent "Advance #{pct.clamp(0, 100)}%"

    msg =
      case @state
      when .title?  then " {#7ef07e-fg}Press ENTER to deploy{/}"
      when .paused? then " {#f7f24a-fg}Paused{/} — P to resume"
      when .dead?   then " {#ff6a4a-fg}K.I.A.{/} — R to retry"
      when .won?    then " {#7ef07e-fg}Fortress taken!{/} — R to replay"
      else               " {#fff36b-fg}Space{/} fire · {#7ef07e-fg}G{/} grenade · Q quit"
      end
    @status.show_message msg
  end
end

Commando.new.run
