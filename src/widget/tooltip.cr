require "./box"

module Crysterm
  class Widget
    # A small floating label shown on hover, modeled after Qt's `QToolTip`.
    #
    # You normally don't create one directly: set any widget's `#tool_tip=` and a
    # tooltip appears near the pointer while the widget is hovered (and hides
    # when the pointer leaves). It can also be driven manually with `#show_at` /
    # `#hide`, the instance-level counterpart of `QToolTip::showText`.
    #
    # NOTE Unlike Qt's `QToolTip`, this is *not* a single shared, static tip:
    # `Widget#tool_tip=` lazily creates one `ToolTip` per widget (see
    # `Widget#show_tool_tip`). Only one is ever visible at a time — the hover
    # handlers hide it on `MouseLeave` — so the behavior matches; the difference is
    # in how many objects exist behind it.
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
      # supplies a `ToolTip` background).
      include Mixin::Overlay

      # Shows the tooltip displaying *text* with its top-left near (*x*, *y*),
      # sized to the text and clamped to stay on-window.
      def show_at(x : Int32, y : Int32, text : String) : Nil
        return unless s = window?
        lines = text.split('\n')

        # Pad each line by one leading space so the text doesn't hug the edge.
        set_content lines.map { |l| " #{l}" }.join('\n')

        # Cascade now so the insets below reflect the themed style. A tooltip is
        # created lazily and shown in the same tick, so on first show it hasn't
        # been cascaded yet: `#style` would fall back to the unstyled floor
        # border and over-measure the height even under a borderless theme.
        s.apply_stylesheet

        # Reserve space for the frame (border + padding) so a bordered tooltip
        # isn't squished into a single collapsed row; under a theme with a
        # background instead of a border these insets are 0. Measure in display
        # cells (`str_width`), not codepoints: a CJK/emoji tooltip measured by
        # `.size` under-sizes the box, wrapping and clipping the text inside it.
        w = (lines.max_of? { |l| str_width l } || 0) + 2 + ihorizontal # one cell of padding each side
        h = lines.size + ivertical

        self.width = w
        self.height = h

        # (*x*, *y*) are absolute screen coordinates, but the tooltip is a
        # top-level child whose `left`/`top` are relative to the window's content
        # origin (`aleft == window.ileft + left`). Subtract the window insets so
        # it lands under the pointer, and clamp to the *inner content* size
        # (`awidth - ihorizontal`, where `ihorizontal` is the total inset) so it can't
        # overshoot into the border/padding on a bordered/padded window.
        inner_w = s.awidth - s.ihorizontal
        inner_h = s.aheight - s.ivertical
        self.left = (x - s.ileft).clamp(0, Math.max(0, inner_w - w))
        self.top = (y - s.itop).clamp(0, Math.max(0, inner_h - h))

        to_front
        show
        s.schedule_render
      end
    end
  end
end
