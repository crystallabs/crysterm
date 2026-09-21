# The reusable TUI of Hunt the Wumpus: a teletype — a scrolling transcript over
# an input line — with a scoreboard pinned in the corner. Nothing here knows
# the game; the cave, the commands and the text live in wumpus.cr, which also
# declares the `CT`/`CW` aliases this file relies on.
class WumpusUI
  getter window : CT::Window

  # Append-only output with sticky-bottom scrolling built in.
  getter transcript : CW::Log

  # The command line; it always holds keyboard focus (see the key handler
  # installed below).
  getter input : CW::LineEdit

  # A small titled box pinned to the top-right corner; the game fills and
  # shows/hides it.
  getter scorebox : CW::GroupBox

  def initialize(@window)
    # A `Border` layout carves the terminal into the teletype's two regions: the
    # scrolling transcript takes the center, the input line docks to the bottom
    # edge. The input declares only its `height: 3` (its own two border rows plus
    # the text row); Border spans it across the width and hands the transcript
    # whatever is left — so there is no `"100%-3"` height and no `top: "100%-3"`
    # to keep in sync with each other whenever the input box's height changes.
    frame = CW::Box.new parent: @window, width: "100%", height: "100%",
      layout: CT::Layout::Dock.new

    # `scroll_on_input` jumps back to the tail on new output even after a
    # manual scroll-up, exactly the teletype behavior a transcript wants.
    @transcript = CW::Log.new \
      scroll_on_input: true,
      layout_hint: :center,
      content: "",
      # `Log` keeps braces literal by default; this transcript is written by
      # the game itself, in tag markup.
      parse_tags: true,
      scrollbar_policy: :as_needed,
      style: CT::Style.new(fg: "white", bg: "#1a1a2e", border: true,
        scrollbar: CT::Style.new(bg: "#5555aa"))

    @input = CW::LineEdit.new \
      layout_hint: :bottom,
      height: 3,
      # Yellow text field, but give the border its own dark background/white
      # rule so it blends into the surrounding chrome (matching the transcript
      # box above) instead of drawing a stark yellow frame.
      style: CT::Style.new(fg: "black", bg: "#e0e000",
        border: CT::Border.new(bg: "#1a1a2e", fg: "white"))

    # Scoreboard: inside the transcript's outer border, overlaying the
    # transcript, whose scroll bar shares this column once the log scrolls;
    # `z-index: 10` floats the box above that bar (theme puts the bar on plane
    # 5) so its right border isn't eaten. See the theme's `.popup`/`Menu`
    # overlays for the same pattern.
    #
    # Deliberately *not* in the `frame` above, and so left on the window's
    # default `Layout::Manual`: this is a floating annotation that sits on top of
    # the transcript, not a region beside it. A dock region would reserve its
    # 15 columns and reflow the text out from under it — and the box appears and
    # disappears with the game's "score" flag, which would make the transcript's
    # width jump. Qt hangs a HUD overlay off the plain parent for the same reason.
    @scorebox = CW::GroupBox.new \
      top: 1,
      right: 1,
      width: 15,
      height: 7,
      title: " Score ",
      parse_tags: true,
      style: CT::Style.new(fg: "white", bg: "#16213e", border: true, margin: CT::Margin.right,
        z_index: 10)

    frame.append @transcript
    frame.append @input
    @window.append @scorebox
    @input.focus

    # Keep typing effortless: a keystroke while focus has drifted off the input
    # box (e.g. after clicking into the transcript) grabs focus back and still
    # delivers that key, so you never have to click the box first. When the box
    # is already focused this is a no-op and the key flows normally.
    @window.on(CT::Event::KeyPress) do |e|
      unless @input.focused?
        @input.focus
        @window.emit_key @input, e
        e.accept
      end
    end
  end
end
