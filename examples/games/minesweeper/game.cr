require "../../../src/crysterm"

require "./ui"

# Minesweeper
# ===========
#
# A grid hides mines; every safe cell you uncover shows how many of its eight
# neighbours are mined. Flag suspected mines and clear every safe cell.
#
# Controls (mouse):
#   * Left-click  - uncover a cell.
#   * Right-click - place / remove a flag (or middle-click).
#   * Left-click a revealed number whose flag count already matches it to
#     "chord": auto-uncover its remaining unflagged neighbours at once.
#
# Controls (keyboard):
#   1 / 2 / 3   start a new Beginner / Intermediate / Expert game
#   n           restart the current difficulty with a fresh board
#   t           cycle the visual theme (Grass / Neon / Classic)
#   q / Ctrl-Q  quit
#
# Same commands available from the "Game" menu; live stats (difficulty, mines
# remaining, elapsed time, game state) show in the status bar.
#
# Niceties:
#   * First-click safety - the first cell you open is never a mine and always
#     opens into a blank area.
#   * A live timer and a remaining-mine counter (mines minus flags).
#
# The program is split in two files. `ui.cr` is the reusable part:
# `MinesweeperUI` builds the frame, the board box, the status bar and the menu
# bar. This file is the game: rules, themes, tile rendering, mouse and key
# handling. To build your own board game on the same chrome, keep `ui.cr` and
# replace this file.
class Minesweeper
  # Each cell is drawn this many columns wide and one row tall. Fixed width lets
  # a click's (x, y) be mapped straight back to a (row, col).
  CELL_W = 3

  # name => {rows, cols, mines}
  DIFFICULTIES = {
    "beginner"     => {9, 9, 10},
    "intermediate" => {16, 16, 40},
    "expert"       => {16, 30, 99},
  }

  # The board is drawn as coloured tiles, not plain text. Each visual theme
  # carries a full palette; the `t` key cycles between them at runtime. Tiles use
  # a two-tone checkerboard (light/dark by cell parity) for covered and dug cells.
  record Theme,
    name : String,
    box_bg : String,               # board frame / border backdrop
    border_type : CT::BorderType,  # frame style (single line, double, …)
    border_fg : String,            # frame colour
    covered : {String, String},    # covered-tile checkerboard {light, dark}
    dug : {String, String},        # dug-cell checkerboard {light, dark}
    numbers : Hash(Int32, String), # neighbour-count colour, 1..8
    flag_fg : String,              # ⚑ on a covered tile
    mine_fg : String,              # ● revealed on the game-over board
    hit_bg : String,               # background of the detonated mine
    hit_fg : String,               # ● of the detonated mine
    correct_bg : String,           # correctly-flagged mine on the finished board
    correct_fg : String,
    wrong_fg : String # ✗ over a wrongly-flagged safe cell

  # Each glyph is a single terminal cell wide so the 3-column tiles stay aligned
  # (emoji would be double-width and break the grid).
  FLAG  = '⚑'
  MINE  = '●'
  WRONG = '✗'

  THEMES = [
    # Bright grass field that "digs" into sandy tan.
    Theme.new(
      name: "Grass",
      box_bg: "#4e7a27", border_type: CT::BorderType::Solid, border_fg: "#86a94e",
      covered: {"#aad751", "#a2d149"}, dug: {"#e5c29f", "#d7b899"},
      numbers: {1 => "#1976d2", 2 => "#388e3c", 3 => "#d32f2f", 4 => "#7b1fa2",
                5 => "#ff8f00", 6 => "#0097a7", 7 => "#424242", 8 => "#757575"},
      flag_fg: "#d32f2f", mine_fg: "#1a1a1a",
      hit_bg: "#d32f2f", hit_fg: "#ffffff",
      correct_bg: "#4caf50", correct_fg: "#10240a", wrong_fg: "#b71c1c"),
    # Slate tiles and bright glyphs, matching the dark menu/status bars.
    Theme.new(
      name: "Neon",
      box_bg: "#0e0e16", border_type: CT::BorderType::Double, border_fg: "#89b4fa",
      covered: {"#2a2a45", "#232338"}, dug: {"#14141f", "#0e0e16"},
      numbers: {1 => "#82aaff", 2 => "#c3e88d", 3 => "#ff5370", 4 => "#c792ea",
                5 => "#ffcb6b", 6 => "#89ddff", 7 => "#eeffff", 8 => "#b2b2c0"},
      flag_fg: "#f38ba8", mine_fg: "#94e2d5",
      hit_bg: "#f38ba8", hit_fg: "#11111a",
      correct_bg: "#a6e3a1", correct_fg: "#11111a", wrong_fg: "#f38ba8"),
    # Flat grey/beige Windows look with traditional numbers.
    Theme.new(
      name: "Classic",
      box_bg: "#9e9e9e", border_type: CT::BorderType::Double, border_fg: "#ffffff",
      covered: {"#c6c6c6", "#bdbdbd"}, dug: {"#d8d2c4", "#cfc8b8"},
      numbers: {1 => "#0000ff", 2 => "#008000", 3 => "#ff0000", 4 => "#000080",
                5 => "#800000", 6 => "#008080", 7 => "#000000", 8 => "#808080"},
      flag_fg: "#ff0000", mine_fg: "#000000",
      hit_bg: "#ff0000", hit_fg: "#000000",
      correct_bg: "#00a000", correct_fg: "#000000", wrong_fg: "#ff0000"),
  ]

  @rows = 9
  @cols = 9
  @mines_total = 10
  @difficulty = "beginner"

  # Board state, all sized @rows x @cols and rebuilt on each new game.
  @mine = [] of Array(Bool)
  @revealed = [] of Array(Bool)
  @flagged = [] of Array(Bool)
  @adj = [] of Array(Int32) # neighbouring-mine count, computed once mines are laid

  # Ready before the first click (mines not yet placed), then Playing, then
  # Won or Lost.
  enum State
    Ready
    Playing
    Won
    Lost
  end
  @state : State = :ready
  @flags = 0
  @revealed_count = 0
  @hit_r = -1 # the mine that was detonated, highlighted on the loss board
  @hit_c = -1

  @started_at : Time::Instant? = nil # monotonic clock at the first click
  @elapsed = 0

  # Index into THEMES of the active visual theme; advanced by the `t` key.
  # Defaults to Neon (resolved by name so it survives reordering THEMES).
  @theme_index = THEMES.index { |t| t.name == "Neon" } || 0

  def initialize(@difficulty)
    @window = CT::Window.new title: "Minesweeper"

    @ui = MinesweeperUI.new(@window,
      board_width: @cols * CELL_W + 2, # +2 for the left/right border
      board_height: @rows + 2,
      difficulties: DIFFICULTIES.keys) { |command| menu_command command }
    @board = @ui.board
    @status = @ui.status

    apply_theme

    # One handler covers the whole board; recover the clicked cell from event
    # coordinates. Acting on `down?` only means one action per press.
    @board.on(CT::Event::Mouse) do |e|
      next unless e.action.down?
      handle_click e
    end

    @window.on(CT::Event::KeyPress) do |e|
      case
      when e.key == Tput::Key::CtrlQ, e.char == 'q'
        # Graceful app-level quit — see `Window#quit` (vs a bare `exit`).
        @window.quit
      when e.char == 'n'
        new_game @difficulty
      when e.char == '1'
        new_game "beginner"
      when e.char == '2'
        new_game "intermediate"
      when e.char == '3'
        new_game "expert"
      when e.char == 't'
        cycle_theme
      end
    end

    # Tick the clock once a second while a game is in progress. `every` owns the
    # fiber, the sleep and the repaint — the body only advances state.
    @window.every(1.second) do
      if @state.playing? && (start = @started_at)
        @elapsed = (Time.instant - start).total_seconds.to_i
        render_status
      end
    end
  end

  # A Game/Help menu entry was activated (see `MinesweeperUI`): the same
  # commands the keyboard offers, plus the two help texts.
  private def menu_command(command : String)
    case command
    when "new"      then new_game @difficulty
    when "theme"    then cycle_theme
    when "quit"     then @window.quit # graceful app-level quit, as for `q`
    when "controls" then @status.show_message " Left-click: reveal · Right-click: flag · click a number to chord · t: theme"
    when "about"    then @status.show_message " Minesweeper — a Crysterm example"
    else                 new_game command if DIFFICULTIES.has_key?(command)
    end
  end

  def run
    new_game @difficulty
    @window.exec
  end

  # ---- Helpers ---------------------------------------------------------------

  # The active visual theme.
  private def theme : Theme
    THEMES[@theme_index]
  end

  # Push the active theme onto the board frame: border style/colour and backdrop.
  # Per-cell colours are read straight from the theme in `cell_glyph`, so a
  # theme change only needs a repaint.
  private def apply_theme
    @board.style.bg = theme.box_bg
    @board.style.border = CT::Border.new(theme.border_type, fg: theme.border_fg)
  end

  # Advance to the next visual theme and repaint.
  private def cycle_theme
    @theme_index = (@theme_index + 1) % THEMES.size
    apply_theme
    refresh
  end

  # Every (row, col) coordinate on the board, as a flat list.
  private def all_cells : Array({Int32, Int32})
    coords = [] of {Int32, Int32}
    @rows.times { |r| @cols.times { |c| coords << {r, c} } }
    coords
  end

  # Yield each in-bounds neighbour (up to eight surrounding cells) of (r, c).
  private def neighbors(r, c, &)
    (-1..1).each do |dr|
      (-1..1).each do |dc|
        next if dr == 0 && dc == 0
        nr, nc = r + dr, c + dc
        yield nr, nc if nr >= 0 && nr < @rows && nc >= 0 && nc < @cols
      end
    end
  end

  # ---- Game setup ------------------------------------------------------------

  private def new_game(name : String)
    @difficulty = name
    @rows, @cols, @mines_total = DIFFICULTIES[name]

    @mine = Array.new(@rows) { Array.new(@cols, false) }
    @revealed = Array.new(@rows) { Array.new(@cols, false) }
    @flagged = Array.new(@rows) { Array.new(@cols, false) }
    @adj = Array.new(@rows) { Array.new(@cols, 0) }

    @state = :ready
    @flags = 0
    @revealed_count = 0
    @hit_r = @hit_c = -1
    @started_at = nil
    @elapsed = 0

    # Resize the board to the new grid before re-rendering.
    @board.width = @cols * CELL_W + 2
    @board.height = @rows + 2

    # Tick the active difficulty in the menu (radio-group behaviour).
    @ui.diff_actions.each { |key, action| action.checked = (key == name) }

    render_status
    render_board
  end

  # Lay mines, keeping the first-clicked cell and its neighbours clear so the
  # opening move always reveals a blank pocket. Called on the first click.
  private def place_mines(safe_r : Int32, safe_c : Int32)
    safe = Set{ {safe_r, safe_c} }
    neighbors(safe_r, safe_c) { |r, c| safe << {r, c} }

    candidates = all_cells.reject { |rc| safe.includes? rc }
    # If the grid is so small that sparing the whole pocket leaves too few
    # cells, fall back to sparing only the clicked cell itself.
    candidates = all_cells.reject { |rc| rc == {safe_r, safe_c} } if candidates.size < @mines_total

    candidates.sample(@mines_total).each { |(r, c)| @mine[r][c] = true }

    # Precompute each cell's neighbouring-mine count.
    all_cells.each do |(r, c)|
      next if @mine[r][c]
      count = 0
      neighbors(r, c) { |nr, nc| count += 1 if @mine[nr][nc] }
      @adj[r][c] = count
    end
  end

  # ---- Input -----------------------------------------------------------------

  private def handle_click(e)
    return unless @state.ready? || @state.playing?

    # Map absolute event coordinates to a grid cell. `contents_rect` is the
    # board's rectangle as painted, already inset past the border.
    return unless (r = @board.contents_rect) && r.contains?(e.x, e.y)

    col = (e.x - r.xi) // CELL_W
    row = e.y - r.yi
    return unless row < @rows && col < @cols

    case e.button
    when Tput::Mouse::Button::Right, Tput::Mouse::Button::Middle
      toggle_flag row, col
    else # Left
      if @revealed[row][col]
        chord row, col # left-click on a number: try to auto-clear neighbours
      else
        reveal row, col
      end
    end

    refresh
  end

  private def toggle_flag(r, c)
    return if @revealed[r][c]
    @flagged[r][c] = !@flagged[r][c]
    @flags += @flagged[r][c] ? 1 : -1
  end

  # Reveal a cell, starting the game (and laying mines) on the first reveal,
  # flood-filling outward from blank cells.
  private def reveal(r, c)
    return if @flagged[r][c] || @revealed[r][c]

    if @state.ready?
      place_mines r, c
      @state = :playing
      @started_at = Time.instant
    end

    if @mine[r][c]
      @hit_r, @hit_c = r, c
      lose
      return
    end

    flood r, c
    win if @revealed_count == @rows * @cols - @mines_total
  end

  # Iterative flood fill: uncover this cell, and if it has no neighbouring mines
  # keep spreading through its neighbours.
  private def flood(r, c)
    stack = [{r, c}]
    until stack.empty?
      cr, cc = stack.pop
      next if @revealed[cr][cc] || @flagged[cr][cc] || @mine[cr][cc]
      @revealed[cr][cc] = true
      @revealed_count += 1
      if @adj[cr][cc] == 0
        neighbors(cr, cc) { |nr, nc| stack << {nr, nc} }
      end
    end
  end

  # "Chord": clicking a revealed number whose adjacent flags already equal its
  # count opens all remaining unflagged neighbours in one go. A wrong flag here
  # can lose the game.
  private def chord(r, c)
    n = @adj[r][c]
    return if n == 0
    flagged_around = 0
    neighbors(r, c) { |nr, nc| flagged_around += 1 if @flagged[nr][nc] }
    return unless flagged_around == n

    neighbors(r, c) do |nr, nc|
      next if @flagged[nr][nc] || @revealed[nr][nc]
      reveal nr, nc
      return if @state.lost? # stop early if a chorded cell was a mine
    end
  end

  # ---- Endgame ---------------------------------------------------------------

  private def lose
    @state = :lost
  end

  private def win
    @state = :won
    # Every non-mine cell is open; flag remaining mines for a 0 remaining-mine count.
    all_cells.each do |(r, c)|
      if @mine[r][c] && !@flagged[r][c]
        @flagged[r][c] = true
        @flags += 1
      end
    end
  end

  # ---- Rendering -------------------------------------------------------------

  # Repaint from current state. Setting content/geometry schedules the frame
  # itself, so there is no explicit render here.
  private def refresh
    render_status
    render_board
  end

  # Mirror live stats into the status bar: game state / key hint as the
  # left-aligned message, difficulty / theme / mines-remaining / time as the
  # right-aligned permanent sections. Permanent sections are plain text, so any
  # colour goes in the message.
  private def render_status
    remaining = @mines_total - @flags
    @status.clear_permanent
    @status.add_permanent @difficulty.capitalize
    @status.add_permanent theme.name
    @status.add_permanent "#{FLAG} #{sprintf("%03d", remaining)}" # mines left
    @status.add_permanent "#{sprintf("%03d", @elapsed.clamp(0, 999))}s"

    # On win/loss show the outcome, otherwise the key hints; kept short since the
    # message and permanent sections share the row.
    message = case @state
              when .won?  then "{green-fg}{bold}YOU WIN!{/}  press n for a new game"
              when .lost? then "{red-fg}{bold}BOOM! You lost.{/}  press n for a new game"
              else             "{#8a8aa0-fg}1/2/3 difficulty · n new · t theme · q quit{/}"
              end
    @status.show_message " #{message}"
  end

  private def render_board
    sb = String::Builder.new
    @rows.times do |r|
      @cols.times do |c|
        sb << cell_glyph(r, c)
      end
      sb << '\n' unless r == @rows - 1
    end
    @board.content = sb.to_s
  end

  # One 3-column tile: a centred glyph over a background, rendered through the
  # truecolor tag form (`{#rrggbb-bg}`/`{#rrggbb-fg}`).
  private def tile(bg : String, fg : String, glyph : Char) : String
    "{#{bg}-bg}{#{fg}-fg} #{glyph} {/}"
  end

  # An empty 3-column tile (covered or dug): just a coloured background.
  private def blank_tile(bg : String) : String
    "{#{bg}-bg}   {/}"
  end

  # The 3-wide drawing for one cell in the active theme. Two-tone checkerboard
  # (by cell parity); a single centred glyph keeps every tile exactly CELL_W
  # columns regardless of tags.
  private def cell_glyph(r, c) : String
    t = theme
    light = (r + c).even?
    covered = light ? t.covered[0] : t.covered[1]
    dug = light ? t.dug[0] : t.dug[1]
    over = @state.won? || @state.lost?
    n = @adj[r][c]

    if over && @mine[r][c]
      # Reveal every mine once the game is over.
      if r == @hit_r && c == @hit_c
        tile t.hit_bg, t.hit_fg, MINE # detonated
      elsif @flagged[r][c]
        tile t.correct_bg, t.correct_fg, FLAG # correctly flagged
      else
        tile dug, t.mine_fg, MINE
      end
    elsif over && @flagged[r][c] && !@mine[r][c]
      tile dug, t.wrong_fg, WRONG # flag on a safe cell
    elsif @flagged[r][c]
      tile covered, t.flag_fg, FLAG
    elsif !@revealed[r][c]
      blank_tile covered
    elsif n == 0
      blank_tile dug
    else
      tile dug, t.numbers[n], '0' + n
    end
  end
end
