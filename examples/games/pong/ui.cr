# The reusable TUI of Pong: the play field and its sprites, the scoreboard, the
# miss overlay and the status bar. Nothing here knows the game; the physics and
# keys live in pong.cr, which also declares the `CT`/`CW` aliases this file
# relies on.
class PongUI
  getter window : CT::Window

  # The play field. It keeps `Layout::Manual` (no engine installed): the
  # paddles, net and ball are *sprites* whose coordinates are pushed onto them
  # by the game every tick. That is what manual placement is for — a
  # child-arranging layout here would fight the simulation for control of
  # top/left every frame. Qt draws its game scenes the same way.
  getter table : CW::Box

  getter lpaddle : CW::Box
  getter rpaddle : CW::Box
  getter ball : CW::Box
  getter score : CW::Box

  # A transient dialog floating over the field; `text` is its one line.
  getter message : CW::Box
  getter text : CW::Box

  getter statusbar : CW::StatusBar

  def initialize(@window, *, paddle_height : Int32)
    # A `Border` layout carves the terminal into the two regions the game needs:
    # the play field takes the center, the status bar docks to the bottom edge.
    # The bar declares only its `height: 1`; Border spans it across the width and
    # gives the field whatever is left — no `"100%-1"` arithmetic to keep in sync
    # with the bar, and nothing pinned to a fixed coordinate.
    frame = CW::Box.new parent: @window, width: "100%", height: "100%",
      layout: CT::Layout::Dock.new

    @table = CW::Box.new parent: frame, layout_hint: :center

    @lpaddle = CW::Box.new parent: @table, width: 1, height: paddle_height, top: 0, left: 0,
      style: CT::Style.new(bg: "yellow")

    @rpaddle = CW::Box.new parent: @table, width: 1, height: paddle_height, top: 0, right: 0,
      style: CT::Style.new(bg: "yellow")

    CW::Box.new parent: @table, width: 1, height: "100%", top: 0, left: "center",
      style: CT::Style.new(bg: "yellow")

    # Created after the net so it renders over the center line instead of
    # vanishing behind it; kept before the scoreboard/overlay so those still
    # sit on top of the ball.
    @ball = CW::Box.new parent: @table, width: 1, height: 1, top: 0, left: 0,
      content: "●", style: CT::Style.new(fg: "white")

    @score = CW::Box.new parent: @table, top: "center", left: "center", height: 3, width: 22,
      align: "center", parse_tags: true, style: CT::Style.new(border: true, bold: true)

    # The overlay floats over the field so — like the scoreboard — it stays
    # centered on the play field rather than occupying a layout slot. Inside
    # it, a `VBox` owns the one text row: `justify: Center` puts it on the
    # middle line and the default `align: Stretch` spans it across the
    # interior, which is already inset by the border.
    @message = CW::Box.new parent: @table, width: "50%", height: 3,
      top: "center", left: "center", style: CT::Style.new(border: true),
      layout: CT::Layout::VBox.new(justify: CT::Layout::Box::Justify::Center)
    @text = CW::Box.new parent: @message, height: 1, align: "center"
    @message.hide

    # Status bar along the very bottom. Docked to the frame's bottom edge; it
    # declares its height, Border does the rest.
    @statusbar = CW::StatusBar.new parent: frame, height: 1,
      layout_hint: :bottom,
      style: CT::Style.new(fg: "white", bg: "#303050")
  end
end
