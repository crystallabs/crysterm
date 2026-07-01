require "./box"

module Crysterm
  class Widget
    # A small floating label shown on hover, modeled after Qt's `QToolTip`.
    #
    # You normally don't create one directly: set any widget's `#tool_tip=` and a
    # shared tooltip appears near the pointer while the widget is hovered (and
    # hides when the pointer leaves). It can also be driven manually with
    # `#show_at` / `#hide`, mirroring `QToolTip::showText`.
    #
    # ```
    # button.tool_tip = "Save the document"
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![ToolTip screenshot](../../tests/widget/tooltip/tooltip.5s.apng)
    # <!-- /widget-examples:capture -->
    class ToolTip < Box
      def initialize(**box)
        super **box
        @parse_tags = true
        # A tooltip is a passive overlay: it must never grab the mouse or focus.
        @clickable = false
        @focus_on_click = false
        # Pale tooltip colors come from the CSS theme (`ToolTip { ... }`),
        # overridable by author CSS or an inline style.
        hide
      end

      # A tooltip is an overlay: at the unstyled floor it carries a structural
      # border so it separates from the content behind it (a theme otherwise
      # supplies a `ToolTip` background; see `Mixin::Style#floor_border?`).
      def floor_border? : Bool
        true
      end

      # Shows the tooltip displaying *text* with its top-left near (*x*, *y*),
      # sized to the text and clamped to stay on-window.
      def show_at(x : Int32, y : Int32, text : String) : Nil
        return unless s = window?
        lines = text.split('\n')

        # Pad each line by one leading space so the text doesn't hug the edge.
        set_content lines.map { |l| " #{l}" }.join('\n')

        # Cascade now so insets below reflect the themed style. The shared
        # tooltip is created lazily and shown in the same tick, so on first
        # show it hasn't been cascaded yet: `#style` would fall back to the
        # unstyled floor border (see `Mixin::Style#ensure_floor_border`) and
        # over-measure the height even under a borderless theme, until a later
        # render cascaded it. Cascading here fixes the first show too.
        s.apply_stylesheet

        # Reserve space for the frame (border + padding) so a bordered tooltip
        # isn't squished into a single collapsed row. Reading `iwidth`/`iheight`
        # resolves `#style` (installing the floor border per `#floor_border?`),
        # so insets reflect the border this render will draw; under a theme with
        # a background instead of a border these insets are 0.
        w = (lines.max_of?(&.size) || 0) + 2 + iwidth # one cell of padding each side
        h = lines.size + iheight

        self.width = w
        self.height = h

        self.left = x.clamp(0, Math.max(0, s.awidth - w))
        self.top = y.clamp(0, Math.max(0, s.aheight - h))

        front!
        show
        s.schedule_render
      end
    end
  end
end
