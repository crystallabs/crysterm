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
    class ToolTip < Box
      def initialize(**box)
        super **box
        @parse_tags = true
        # A tooltip is a passive overlay: it must never grab the mouse or focus.
        @clickable = false
        @focus_on_click = false
        # Classic pale tooltip colors, unless the caller supplied a style.
        @style = Style.new(fg: "black", bg: "yellow") if @style.nil?
        hide
      end

      # Shows the tooltip displaying *text* with its top-left near (*x*, *y*),
      # sized to the text and clamped to stay on-screen.
      def show_at(x : Int32, y : Int32, text : String) : Nil
        return unless s = screen?
        lines = text.split('\n')
        w = (lines.max_of?(&.size) || 0) + 2 # one cell of padding each side
        h = lines.size

        # Pad each line by one leading space so the text doesn't hug the edge.
        set_content lines.map { |l| " #{l}" }.join('\n')
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
