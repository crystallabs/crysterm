require "../../../src/crysterm"

# Term Pong.
#
# Controls: up / down move both paddles; `a` / `z` move the left paddle and
# `k` / `m` the right one. `+` / `-` change the ball speed and `1`-`9` set a
# speed level (`0` stops it); q or Escape quits.
class Pong
  include Crysterm
  include Crysterm::Widgets

  PADDLE_H     = 6
  PADDLE_SPEED = 2

  # Fixed FPS loop; speed is a velocity, not a frame rate. The level (0..9)
  # sets cells/second — MAX_SPEED at level 9, dead stop at 0 — and the
  # per-tick step is that ÷ FPS. `+`/`-` step the level, `0`-`9` set it
  # directly (see key handler in `initialize`).
  #
  # Speed is held constant between hits; only the angle changes on a paddle
  # hit. ASPECT compensates for the ~2:1 terminal cell so an on-screen
  # diagonal looks ~45° instead of racing vertically. See `set_vel`.
  FPS         =   60                # fixed render/step rate
  MAX_SPEED   = 80.0                # cells/second at level 9
  SPEED_STEP  = MAX_SPEED / 9 / FPS # cells-per-tick added per speed level
  START_LEVEL =   5
  ASPECT      = 2.0

  # Mutable game state. The ball's position and velocity live in fractional
  # cell-space; it is rendered at the rounded cell.
  @ball_l = 1.0
  @ball_t = 1.0
  @level = START_LEVEL                        # speed level: 0 (stalled) .. 9 (MAX_SPEED)
  @speed : Float64 = START_LEVEL * SPEED_STEP # current ball speed (cells/tick), from @level
  @vel_l : Float64 = START_LEVEL * SPEED_STEP
  @vel_t = 0.0
  @lpad_t = 0
  @rpad_t = 0
  @score_l = 0
  @score_r = 0
  @moving = true

  def initialize
    @window = Window.new title: "pong.cr"

    # A `Border` layout carves the terminal into the two regions the game needs:
    # the play field takes the center, the status bar docks to the bottom edge.
    # The bar declares only its `height: 1`; Border spans it across the width and
    # gives the field whatever is left — no `"100%-1"` arithmetic to keep in sync
    # with the bar, and nothing pinned to a fixed coordinate.
    frame = Box.new parent: @window, width: "100%", height: "100%",
      layout: Layout::Border.new

    # Play field. It keeps `Layout::Manual` (no engine installed): the paddles,
    # net and ball are *sprites* whose coordinates are the game state, pushed
    # onto them every tick by `sync`. That is what manual placement is for — a
    # child-arranging layout here would fight the simulation for control of
    # top/left every frame. Qt draws its game scenes the same way.
    @table = Box.new parent: frame, layout_hint: :center

    @lpaddle = Box.new parent: @table, width: 1, height: PADDLE_H, top: 0, left: 0,
      style: Style.new(bg: "yellow")

    @rpaddle = Box.new parent: @table, width: 1, height: PADDLE_H, top: 0, right: 0,
      style: Style.new(bg: "yellow")

    Box.new parent: @table, width: 1, height: "100%", top: 0, left: "center",
      style: Style.new(bg: "yellow")

    # Created after the net so it renders over the center line instead of
    # vanishing behind it; kept before the scoreboard/overlay so those still
    # sit on top of the ball.
    @ball = Box.new parent: @table, width: 1, height: 1, top: 0, left: 0,
      content: "●", style: Style.new(fg: "white")

    @score = Box.new parent: @table, top: "center", left: "center", height: 3, width: 22,
      align: "center", parse_tags: true, style: Style.new(border: true, bold: true)

    # A transient dialog floating over the field, so — like the scoreboard — it
    # stays centered on the play field rather than occupying a layout slot.
    # Inside it, though, a `VBox` owns the one text row: `justify: Center` puts
    # it on the middle line and the default `align: Stretch` spans it across the
    # interior, which is already inset by the border. That replaces the row's
    # hand-computed `top: "center", left: 1, right: 1`.
    @message = Box.new parent: @table, width: "50%", height: 3,
      top: "center", left: "center", style: Style.new(border: true),
      layout: Layout::VBox.new(justify: Layout::Box::Justify::Center)
    # Overlay shown briefly on a miss; `lose` fills in the text before each show.
    @text = Box.new parent: @message, height: 1, align: "center"
    @message.hide

    # Status bar along the very bottom: the controls on the left. Docked to the
    # frame's bottom edge; it declares its height, Border does the rest.
    statusbar = StatusBar.new parent: frame, height: 1,
      layout_hint: :bottom,
      style: Style.new(fg: "white", bg: "#303050")
    statusbar.show_message " Keys: left: a/z, right: k/m, both: up/down"

    @window.on(Event::KeyPress) do |e|
      case
      when e.char == 'q' || e.key == Tput::Key::Escape
        @window.quit
      when e.key == Tput::Key::Up
        move_paddles(-PADDLE_SPEED, -PADDLE_SPEED)
      when e.key == Tput::Key::Down
        move_paddles(PADDLE_SPEED, PADDLE_SPEED)
      when e.char == 'a'
        move_paddles(-PADDLE_SPEED, 0)
      when e.char == 'z'
        move_paddles(PADDLE_SPEED, 0)
      when e.char == 'm'
        move_paddles(0, PADDLE_SPEED)
      when e.char == 'k'
        move_paddles(0, -PADDLE_SPEED)
      when e.char == '+' || e.char == '='
        set_level(@level + 1)
      when e.char == '-' || e.char == '_'
        set_level(@level - 1)
      when e.char.ascii_number?
        # 0 stops the ball; 1-9 set the speed level, 9 being MAX_SPEED.
        set_level(e.char.to_i)
      end
    end

    @window.on(Event::Resize) { sync }
  end

  def run
    reset
    # Fixed render rate; the level carries the speed via the velocity, not the rate.
    @window.every((1.0 / FPS).seconds) { tick }
    @window.exec
  end

  # Build a velocity from a desired vertical component and horizontal direction
  # (dir: +1 right, -1 left), keeping the total (aspect-weighted) speed equal to
  # the current `@speed`. vy is clamped so the horizontal component never
  # vanishes — no vertical stalls.
  private def set_vel(vy : Float64, dir : Int32) : {Float64, Float64}
    cap = @speed / ASPECT * 0.85
    vy = vy.clamp(-cap, cap)
    vx = Math.sqrt(@speed ** 2 - (ASPECT * vy) ** 2)
    {dir * vx, vy}
  end

  # Push the state onto the widgets. Each assignment schedules the frame that
  # paints it, so there is no explicit render here.
  #
  # Deliberately does not erase previous positions by hand: the renderer clears
  # the whole buffer and re-composites every frame. Manual erasing (the old
  # `clear_last_rendered_position` call) raced the async renderer and made
  # stationary paddles flicker — see git history.
  private def sync
    @ball.left = @ball_l.round.to_i
    @ball.top = @ball_t.round.to_i
    @lpaddle.top = @lpad_t
    @rpaddle.top = @rpad_t
    @score.content = "{green-fg}Score:{/green-fg} #{@score_l} | #{@score_r}"
  end

  private def reset
    @message.hide
    @moving = true
    @ball_t = 1.0
    # Alternate the serve direction by total score, sending the ball toward the
    # side that is about to receive, at a gentle downward angle.
    if (@score_l + @score_r) % 2 != 0
      @ball_l = (@table.awidth - 2).to_f
      @vel_l, @vel_t = set_vel 0.12, -1
    else
      @ball_l = 1.0
      @vel_l, @vel_t = set_vel 0.12, 1
    end
    @lpad_t = 0
    @rpad_t = 0
    sync
  end

  private def lose(msg : String)
    @moving = false
    @text.content = msg
    @message.show
    spawn do
      sleep 1.second
      reset
    end
  end

  private def tick
    return unless @moving
    w = @table.awidth
    h = @table.aheight

    @ball_l += @vel_l
    @ball_t += @vel_t

    # Bounce off the top and bottom walls.
    if @ball_t < 0
      @ball_t = 0.0
      @vel_t = @vel_t.abs
    elsif @ball_t > h - 1
      @ball_t = (h - 1).to_f
      @vel_t = -@vel_t.abs
    end

    # Judge the paddle hit against the rendered row (`@ball.top` is `@ball_t`
    # rounded), so the verdict matches what the player sees. Paddle occupies
    # rows `pad_t .. pad_t + PADDLE_H - 1`.
    by = @ball_t.round.to_i

    # Right side: bounce off the right paddle, or the right player loses.
    if @vel_l > 0 && @ball_l >= w - 2
      if by >= @rpad_t && by <= @rpad_t + PADDLE_H - 1
        @ball_l = (w - 2).to_f
        # Steeper deflection the further the hit is from the paddle's centre.
        @vel_l, @vel_t = set_vel @vel_t + (by - (@rpad_t + PADDLE_H // 2)) * 0.06, -1
      else
        # Miss: let the ball sail to the wall so the loss is visible on screen.
        @ball_l = (w - 1).to_f
        sync
        @score_l += 1
        lose "Right player loses!"
        return
      end
      # Left side: bounce off the left paddle, or the left player loses.
    elsif @vel_l < 0 && @ball_l <= 1
      if by >= @lpad_t && by <= @lpad_t + PADDLE_H - 1
        @ball_l = 1.0
        @vel_l, @vel_t = set_vel @vel_t + (by - (@lpad_t + PADDLE_H // 2)) * 0.06, 1
      else
        @ball_l = 0.0
        sync
        @score_r += 1
        lose "Left player loses!"
        return
      end
    end

    sync
  end

  # Set the speed level (0..9), rescaling the in-flight velocity so the ball
  # keeps its heading. From a standstill it restarts horizontally in its last
  # direction.
  private def set_level(l : Int32)
    @level = l.clamp(0, 9)
    @speed = @level * SPEED_STEP
    mag = Math.sqrt(@vel_l ** 2 + (ASPECT * @vel_t) ** 2)
    if mag > 1e-6
      r = @speed / mag
      @vel_l *= r
      @vel_t *= r
    else
      @vel_l, @vel_t = set_vel 0.0, (Math.copysign(1.0, @vel_l) < 0 ? -1 : 1)
    end
  end

  # Move each paddle by its own delta (0 = leave it put), clamped to the field.
  private def move_paddles(dl : Int32, dr : Int32)
    return unless @moving
    max = @table.aheight - PADDLE_H
    @lpad_t = (@lpad_t + dl).clamp(0, max)
    @rpad_t = (@rpad_t + dr).clamp(0, max)
    sync
  end
end

Pong.new.run
