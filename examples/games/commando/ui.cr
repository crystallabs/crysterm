# The reusable TUI of Commando: a fixed-width play field centered in the
# terminal, a status bar under it, and two floating cards (a centered overlay
# and a slim top banner). Nothing here knows the game; the level, simulation
# and scene painting live in commando.cr, which also declares the `CT`/`CW`
# aliases this file relies on.

# The play-window widget: a bordered box whose `#paint` runs during the
# compositor's pass (after its buffer clear), then hands off to the `painter`
# proc to overpaint the scene.
class Field < Crysterm::Widget::Box
  property painter : (Field ->)? = nil

  def paint(*, with_children = true)
    super
    painter.try &.call(self)
  end
end

class CommandoUI
  getter window : CT::Window

  # The play field; set its `painter` to draw the scene.
  getter field : Field

  getter status : CW::StatusBar

  # Centered card for title / pause / game-over / victory screens.
  getter overlay : CW::Box

  # A slim top banner, so live gameplay stays visible below it.
  getter banner : CW::Box

  def initialize(@window, *, field_width : Int32)
    # The cabinet: one frame holding the two stacked regions — the play field
    # above, the status bar below. `Window` is not a `Widget`, so the layout
    # hangs off a full-screen box.
    #
    # A `VBox` rather than a `Border` dock, because the vertical stack is only
    # half the job: the play field is a *fixed* width and must sit centered in
    # whatever terminal it finds itself in. `align: Center` is the box's cross
    # axis, so the field is centered horizontally for free; the field then takes
    # no explicit height and flexes into everything the status bar leaves. Qt
    # would write this the same way: a QVBoxLayout with the arena added under
    # Qt::AlignHCenter.
    frame = CW::Box.new parent: @window, width: "100%", height: "100%",
      layout: CT::Layout::VBox.new(align: CT::Layout::Box::Align::Center)

    # Damage tracking (the default) stays on: the one widget whose cells change
    # without tracked setters — the play field, painted by its `painter` proc —
    # opts in via `repaints_every_frame`, so the rest of the UI (status bar,
    # overlays) keeps selective repaints.
    @field = Field.new \
      parent: frame,
      width: field_width,
      repaints_every_frame: true,
      style: CT::Style.new(fg: "white", bg: "#101410",
        border: CT::Border.new(CT::BorderType::Solid, fg: "#6a6a72"))

    # The one row the field doesn't get. Only the size along the stacking axis is
    # declared; the box supplies the row it lands on. (`width` stays explicit:
    # under `align: Center` the cross axis is *not* stretched, so the bar has to
    # ask for the full width it wants to span.)
    @status = CW::StatusBar.new \
      parent: frame,
      width: "100%",
      height: 1,
      parse_tags: true,
      style: CT::Style.new(fg: "white", bg: "#20241c")

    # Overlays deliberately stay outside the layout: they are not regions of the
    # frame but cards that float ON TOP of the live scene, so they keep their own
    # coordinates (as a Qt overlay child would) and remain children of the screen
    # — created after `frame`, hence composited over it rather than overpainted.
    @overlay = CW::Box.new \
      parent: @window,
      top: "center",
      left: "center",
      width: 46,
      height: 11,
      parse_tags: true,
      align: "center",
      style: CT::Style.new(fg: "white", bg: "#14180f", bold: true,
        border: CT::Border.new(CT::BorderType::Double, fg: "#c8b048"))

    @banner = CW::Box.new \
      parent: @window,
      top: 1,
      left: "center",
      width: 48,
      height: 6,
      parse_tags: true,
      align: "center",
      style: CT::Style.new(fg: "white", bg: "#14180f", bold: true,
        border: CT::Border.new(CT::BorderType::Double, fg: "#c8b048"))
    @banner.hide
  end
end
