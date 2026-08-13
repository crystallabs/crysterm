# FEATURE: scripted gameplay — Minesweeper plays itself.
#
# The actual game from examples/games/minesweeper (reused verbatim via its
# `game.cr` support file), opened at Intermediate difficulty with the Grass
# theme and driven through the same code paths as a real player: synthetic
# mouse clicks (`Window#dispatch_mouse`) reveal cells and plant flags, and a
# synthetic `n` keypress starts the next round.
#
# The script is a 5.0 s cycle — fresh board, opening click, steady play with
# flags, a closing sweep to the win, then a new game — that divides the
# capture length exactly and ends back on the fresh covered board it started
# on, so the recording loops seamlessly at any phase. Mines are laid with a
# fixed-seed RNG, making every cycle frame-identical.

require "../../examples/games/minesweeper/game"

class Minesweeper
  # The cell the "player" last acted on; each next move is picked nearest to
  # it, so the play walks the board like a pointer instead of teleporting.
  @demo_at = {8, 8}

  # Deterministic mine layout: a fixed seed plus the same first click lays the
  # same board every cycle, so consecutive cycles render identically and the
  # capture's loop seam is invisible. Otherwise a verbatim copy of the game's
  # own `place_mines`.
  private def place_mines(safe_r : Int32, safe_c : Int32)
    safe = Set{ {safe_r, safe_c} }
    neighbors(safe_r, safe_c) { |r, c| safe << {r, c} }

    candidates = all_cells.reject { |rc| safe.includes? rc }
    candidates = all_cells.reject { |rc| rc == {safe_r, safe_c} } if candidates.size < @mines_total

    candidates.sample(@mines_total, Random.new(20260813)).each { |(r, c)| @mine[r][c] = true }

    all_cells.each do |(r, c)|
      next if @mine[r][c]
      count = 0
      neighbors(r, c) { |nr, nc| count += 1 if @mine[nr][nc] }
      @adj[r][c] = count
    end
  end

  # Click cell (row, col) with *button* through the real dispatch chain, as a
  # terminal would report it: a press and a release at the cell's center.
  private def demo_click(row, col, button = ::Tput::Mouse::Button::Left)
    return unless r = @board.contents_rect
    x = r.xi + col * CELL_W + 1
    y = r.yi + row
    {::Tput::Mouse::Action::Down, ::Tput::Mouse::Action::Up}.each do |action|
      @window.dispatch_mouse ::Tput::Mouse::Event.new(action, button, x, y)
    end
    @demo_at = {row, col}
  end

  # Unrevealed, unflagged cells touching the opened region — the cells a human
  # would reason about — split by whether they hide a mine (the script "knows"
  # the board, standing in for a player reading the numbers).
  private def demo_frontier(mine : Bool) : Array({Int32, Int32})
    all_cells.select do |(r, c)|
      next false if @revealed[r][c] || @flagged[r][c] || @mine[r][c] != mine
      near = false
      neighbors(r, c) { |nr, nc| near = true if @revealed[nr][nc] }
      near
    end
  end

  # The frontier cell nearest the previous move (ties row-major, so the choice
  # is deterministic).
  private def demo_nearest(cells : Array({Int32, Int32})) : {Int32, Int32}
    ar, ac = @demo_at
    cells.min_by { |(r, c)| {Math.max((r - ar).abs, (c - ac).abs), r, c} }
  end

  def demo_run
    @theme_index = THEMES.index { |t| t.name == "Grass" } || 0
    apply_theme
    new_game "intermediate"
    @board.focus # focus up front, so cycle 1's fresh frames match later cycles'

    tick = 0
    @window.every(1.seconds) do
      t = tick % 5 # 5 beats x 1 s = the 5 s capture, wrapping on the fresh board
      tick += 1

      case t
      when 1 # the opening click, dead center — floods open the safe pocket
        demo_click 8, 8
      when 2, 3 # steady play: reveal along the frontier, flag a known mine every 5th beat
        cells = demo_frontier(mine: t % 5 == 2)
        unless cells.empty?
          row, col = demo_nearest(cells)
          demo_click row, col, t % 5 == 2 ? ::Tput::Mouse::Button::Right : ::Tput::Mouse::Button::Left
        end
      when 4,5 # closing sweep: open the rest outward from the last move, winning on the last beat
        ar, ac = @demo_at
        rest = all_cells.select { |(r, c)| !@mine[r][c] && !@revealed[r][c] && !@flagged[r][c] }
        rest.sort_by! { |(r, c)| {Math.max((r - ar).abs, (c - ac).abs), r, c} }
        rest.first(t == 40 ? rest.size : rest.size // (41 - t)).each { |(r, c)| reveal r, c }
        refresh
      when 100 # savor the win, then start the next round the way a player would
        @window.emit Event::KeyPress, Event::KeyPress.new('n', nil)
      end
    end

    @window.exec
  end
end

Minesweeper.new("intermediate").demo_run
