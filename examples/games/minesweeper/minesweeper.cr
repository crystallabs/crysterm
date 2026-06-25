require "../../../src/crysterm"

# Minesweeper
# ===========
#
# The classic. A grid hides a number of mines; every safe cell you uncover
# shows how many of its eight neighbours are mined. Use that to deduce where
# the mines are, flag them, and clear every safe cell without detonating one.
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
#   q / Ctrl-Q  quit
#
# The same commands are available from the "Game" menu in the menu bar at the
# top; the live stats (difficulty, mines remaining, elapsed time, game state)
# show in the status bar along the bottom.
#
# Niceties:
#   * First-click safety - the first cell you open is never a mine, and is
#     guaranteed to open into a blank area, so no game is lost on move one.
#   * A live timer and a remaining-mine counter (mines minus flags).
class Minesweeper
  include Crysterm

  # Each cell is drawn this many columns wide and one row tall. Fixed width is
  # what lets a click's (x, y) be mapped straight back to a (row, col).
  CELL_W = 3

  # name => {rows, cols, mines}
  DIFFICULTIES = {
    "beginner"     => {9, 9, 10},
    "intermediate" => {16, 16, 40},
    "expert"       => {16, 30, 99},
  }

  # Classic per-number colours, indexed by the neighbour count 1..8.
  NUMBER_COLOR = {
    1 => "blue", 2 => "green", 3 => "red", 4 => "magenta",
    5 => "yellow", 6 => "cyan", 7 => "white", 8 => "gray",
  }

  @rows = 9
  @cols = 9
  @mines_total = 10
  @difficulty = "beginner"

  # Board state, all sized @rows x @cols and rebuilt on each new game.
  @mine = [] of Array(Bool)
  @revealed = [] of Array(Bool)
  @flagged = [] of Array(Bool)
  @adj = [] of Array(Int32) # neighbouring-mine count, computed once mines are laid

  # :ready before the first click (mines not yet placed), then :playing, and
  # finally :won or :lost.
  @state = :ready
  @flags = 0
  @revealed_count = 0
  @hit_r = -1 # the mine that was detonated, highlighted on the loss board
  @hit_c = -1

  @started_at : Time::Instant? = nil # monotonic clock at the first click
  @elapsed = 0

  # The checkable difficulty entries in the Game menu, kept so the current one
  # can be shown ticked (they behave like a radio group).
  @diff_actions = {} of String => Action
  @menubar : Widget::MenuBar? = nil

  def initialize(@difficulty)
    @screen = Screen.new title: "Minesweeper"

    @board = Widget::Box.new \
      top: 2,
      left: "center",
      width: @cols * CELL_W + 2, # +2 for the left/right border
      height: @rows + 2,
      parse_tags: true,
      style: Style.new(fg: "white", bg: "#101018", border: true)

    @status = Widget::StatusBar.new \
      parent: @screen,
      bottom: 0,
      left: 0,
      width: "100%",
      height: 1,
      parse_tags: true,
      style: Style.new(fg: "white", bg: "#303050")

    @screen.append @board

    # Built last so its drop-down menus append over the board (and after the
    # widgets the menu actions reference exist).
    build_menu_bar

    # One handler covers the whole board; we recover the clicked cell from the
    # event coordinates. Acting on `down?` only means one action per press.
    @board.on(Event::Mouse) do |e|
      next unless e.action.down?
      handle_click e
    end

    @screen.on(Event::KeyPress) do |e|
      case
      when e.key == Tput::Key::CtrlQ, e.char == 'q'
        @screen.destroy
        exit
      when e.char == 'n'
        new_game @difficulty
      when e.char == '1'
        new_game "beginner"
      when e.char == '2'
        new_game "intermediate"
      when e.char == '3'
        new_game "expert"
      end
    end

    # Tick the timer once a second while a game is in progress.
    spawn do
      loop do
        sleep 1.second
        if @state == :playing && (start = @started_at)
          @elapsed = (Time.instant - start).total_seconds.to_i
          render_status
          @screen.render
        end
      end
    end
  end

  # Build the top menu bar: a "Game" menu mirroring every keyboard command, and
  # a "Help" menu. The difficulty entries are checkable and act as a radio group
  # (the current one is ticked), updated in `new_game`.
  private def build_menu_bar
    menubar = @menubar = Widget::MenuBar.new \
      parent: @screen,
      top: 0,
      left: 0,
      width: "100%",
      height: 1,
      menu_style: Style.new(border: true, fg: "white", bg: "#202030"),
      style: Style.new(fg: "white", bg: "#303050")

    game = menubar.add_menu "Game"
    game.add("New") { new_game @difficulty }
    game.add_separator
    DIFFICULTIES.each_key do |name|
      action = game.add(name.capitalize) { new_game name }
      action.checkable = true
      @diff_actions[name] = action
    end
    game.add_separator
    game.add("Quit") do
      @screen.destroy
      exit
    end

    help = menubar.add_menu "Help"
    help.add("Controls") do
      @status.show_message \
        " Left-click: reveal · Right-click: flag · click a number to chord"
      @screen.render
    end
    help.add("About") do
      @status.show_message " Minesweeper — a Crysterm example"
      @screen.render
    end
  end

  def run
    new_game @difficulty
    @screen.exec
  end

  # ---- Helpers ---------------------------------------------------------------

  # Yield each in-bounds neighbour (the up-to-eight surrounding cells) of (r, c).
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
    @diff_actions.each { |key, action| action.checked = (key == name) }

    render_status
    render_board
    @screen.render
  end

  # Lay the mines, keeping the first-clicked cell and its neighbours clear so
  # the opening move always reveals a blank pocket. Called on the first click.
  private def place_mines(safe_r : Int32, safe_c : Int32)
    forbidden = Set(Tuple(Int32, Int32)).new
    neighbors(safe_r, safe_c) { |r, c| forbidden << {r, c} }
    forbidden << {safe_r, safe_c}

    cells = [] of Tuple(Int32, Int32)
    @rows.times do |r|
      @cols.times do |c|
        cells << {r, c} unless forbidden.includes?({r, c})
      end
    end

    # If the grid is so small that the safe zone leaves too few cells, fall back
    # to forbidding only the clicked cell itself.
    if cells.size < @mines_total
      cells = [] of Tuple(Int32, Int32)
      @rows.times do |r|
        @cols.times { |c| cells << {r, c} unless r == safe_r && c == safe_c }
      end
    end

    cells.shuffle.first(@mines_total).each do |(r, c)|
      @mine[r][c] = true
    end

    # Precompute each cell's neighbouring-mine count.
    @rows.times do |r|
      @cols.times do |c|
        next if @mine[r][c]
        count = 0
        neighbors(r, c) { |nr, nc| count += 1 if @mine[nr][nc] }
        @adj[r][c] = count
      end
    end
  end

  # ---- Input -----------------------------------------------------------------

  private def handle_click(e)
    return unless @state == :ready || @state == :playing

    # Map absolute event coordinates to a grid cell using the board's inner
    # (post-border) origin.
    origin_x = @board.aleft(true) + @board.ileft
    origin_y = @board.atop(true) + @board.itop
    return if e.x < origin_x || e.y < origin_y

    col = (e.x - origin_x) // CELL_W
    row = e.y - origin_y
    return unless row >= 0 && row < @rows && col >= 0 && col < @cols

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

  # Reveal a single cell, starting the game (and laying mines) on the very first
  # reveal and flood-filling outward from blank cells.
  private def reveal(r, c)
    return if @flagged[r][c] || @revealed[r][c]

    if @state == :ready
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
  # keep spreading through its neighbours (classic "open area" behaviour).
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
  # count opens all of its remaining, unflagged neighbours in one go. A wrong
  # flag here can lose the game — exactly as in the original.
  private def chord(r, c)
    n = @adj[r][c]
    return if n == 0
    flagged_around = 0
    neighbors(r, c) { |nr, nc| flagged_around += 1 if @flagged[nr][nc] }
    return unless flagged_around == n

    neighbors(r, c) do |nr, nc|
      next if @flagged[nr][nc] || @revealed[nr][nc]
      reveal nr, nc
      return if @state == :lost # stop early if a chorded cell was a mine
    end
  end

  # ---- Endgame ---------------------------------------------------------------

  private def lose
    @state = :lost
  end

  private def win
    @state = :won
    # A win implies every non-mine cell is open, so flag all mines for a tidy
    # finished board and a 0 remaining-mine count.
    @rows.times do |r|
      @cols.times do |c|
        if @mine[r][c] && !@flagged[r][c]
          @flagged[r][c] = true
          @flags += 1
        end
      end
    end
  end

  # ---- Rendering -------------------------------------------------------------

  private def refresh
    render_status
    render_board
    @screen.render
  end

  # Mirror the live stats into the status bar: the game state (and a hint) as
  # the left-aligned message, the difficulty / mines-remaining / time as the
  # right-aligned permanent sections. The permanent sections are plain text, so
  # any colour goes in the message.
  private def render_status
    remaining = @mines_total - @flags
    @status.clear_permanent
    @status.add_permanent @difficulty.capitalize
    @status.add_permanent "Mines #{sprintf("%03d", remaining)}"
    @status.add_permanent "Time #{sprintf("%03d", @elapsed.clamp(0, 999))}"

    message = case @state
              when :won   then "{green-fg}{bold} YOU WIN!{/}  press n for a new game"
              when :lost  then "{red-fg}{bold} BOOM! You lost.{/}  press n for a new game"
              when :ready then " Click any cell to begin"
              else             " Playing…"
              end
    @status.show_message message
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

  # The 3-wide drawing for one cell, given the current game state. Spaces plus a
  # single character keep every cell exactly CELL_W columns regardless of tags.
  private def cell_glyph(r, c) : String
    over = @state == :won || @state == :lost

    # Reveal mines once the game is over.
    if over && @mine[r][c]
      if r == @hit_r && c == @hit_c
        return "{red-bg}{white-fg} * {/}" # the one you detonated
      elsif @flagged[r][c]
        return "{green-bg}{black-fg} F {/}" # correctly flagged
      else
        return "{black-bg}{red-fg} * {/}"
      end
    end

    # A flag on a cell that turned out to be safe, shown after a loss.
    if over && @flagged[r][c] && !@mine[r][c]
      return "{red-bg}{white-fg} X {/}"
    end

    if @flagged[r][c]
      return "{gray-bg}{red-fg} F {/}"
    end

    unless @revealed[r][c]
      return "{gray-bg}   {/}" # covered tile
    end

    n = @adj[r][c]
    if n == 0
      "{black-bg}   {/}"
    else
      "{black-bg}{#{NUMBER_COLOR[n]}-fg} #{n} {/}"
    end
  end
end

# Pick the difficulty from the first CLI argument (name or 1/2/3); default to
# Beginner.
arg = ARGV[0]?.try(&.downcase)
difficulty =
  case arg
  when "1", "b", "beginner"            then "beginner"
  when "2", "i", "intermediate", "med" then "intermediate"
  when "3", "e", "expert", "hard"      then "expert"
  else                                      "beginner"
  end

Minesweeper.new(difficulty).run
