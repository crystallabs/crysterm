# The reusable TUI of the Minesweeper game: the frame, the board, the status
# bar and the menu bar. Nothing here knows the rules; those live in game.cr,
# which also declares the `CT`/`CW` aliases this file relies on.
#
# A single Border layout carves the window into three regions: the menu bar on
# top, the status bar at the bottom, and the play area filling whatever is left
# in between. Nothing below is placed at a hand-computed coordinate, and no
# region has to reserve room for another.
class MinesweeperUI
  getter window : CT::Window

  # The board: a titled, bordered box whose content is the tile grid.
  getter board : CW::GroupBox

  getter status : CW::StatusBar
  getter menubar : CW::MenuBar

  # The checkable difficulty entries in the Game menu, by difficulty name, so
  # the current one can be shown ticked (they behave like a radio group).
  getter diff_actions = {} of String => CW::Action

  # *difficulties* names the Game menu's checkable entries. Every menu action
  # reports to *command* with one of: `"new"`, a difficulty name, `"theme"`,
  # `"quit"`, `"controls"`, `"about"`.
  def initialize(@window, *, board_width : Int32, board_height : Int32,
                 difficulties : Enumerable(String), &command : String ->)
    frame = CW::Box.new parent: @window, width: "100%", height: "100%",
      layout: CT::Layout::Dock.new

    # The play area: whatever the two bars leave over. The board is the only
    # thing in it, so this box carries no engine of its own — the board sits in
    # the default `Layout::Manual`, self-centring (below). A `VBox(align:
    # Center)` would be the Qt idiom for centring a fixed-size panel, but the
    # two disagree by a column on an odd leftover: `left: "center"` rounds the
    # spare column to the left (mid − half), the box engine floors
    # `(area − board) / 2` and rounds it to the right. Keeping `"center"` keeps
    # the board where it has always been drawn.
    board_area = CW::Box.new parent: frame, layout_hint: :center

    # The board declares its size and asks to be centred in the play area; that
    # area's position and extent come from the layout, so the board does not
    # know a menu bar or a status bar exists. Its top margin — not a `top:`
    # counted off the menu bar's height — is the row of breathing space above it.
    @board = CW::GroupBox.new \
      parent: board_area,
      left: "center",
      width: board_width,
      height: board_height,
      title: " MINESWEEPER ",
      parse_tags: true,
      style: CT::Style.new(fg: "white", border: true, margin: CT::Margin.top, shadow: true)

    @status = CW::StatusBar.new \
      parent: frame,
      height: 1, # the only size it declares: Border spans it across the window
      parse_tags: true,
      layout_hint: :bottom,
      style: CT::Style.new(fg: "white", bg: "#303050")

    # Built last so its drop-down menus append over the board. The pop-ups
    # parent themselves to the window (not to `frame`), so they stay outside
    # the layout and float.
    @menubar = CW::MenuBar.new \
      parent: frame,
      height: 1,
      layout_hint: :top,
      menu_style: CT::Style.new(border: true, fg: "white", bg: "#202030"),
      style: CT::Style.new(fg: "white", bg: "#303050")

    game = @menubar.add_menu "Game"
    game.add_action("New") { command.call "new" }
    game.add_separator
    difficulties.each do |name|
      action = game.add_action(name.capitalize) { command.call name }
      action.checkable = true
      @diff_actions[name] = action
    end
    game.add_separator
    game.add_action("Cycle theme") { command.call "theme" }
    game.add_separator
    game.add_action("Quit") { command.call "quit" }

    help = @menubar.add_menu "Help"
    help.add_action("Controls") { command.call "controls" }
    help.add_action("About") { command.call "about" }
  end
end
