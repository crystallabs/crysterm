require "./nav_keys"

module Crysterm
  module Mixin
    # The "is interactive" concern — a focusable widget that accepts keyboard
    # input and scrolls its viewport with the arrow/paging keys.
    #
    # Qt distributes focus/key handling per widget; Crysterm centralizes it in
    # `Widget::Input` (`Box` + this mixin). Since Crystal is single-inheritance, a
    # widget that must root in a different Qt base — e.g. `PlainTextEdit`, whose
    # ancestor is `QAbstractScrollArea` — can't also be an `Input`, so it includes
    # `Mixin::Interactive` directly instead.
    #
    # Sets the widget interactive (`@input`) and freely-resizable (`@resizable`),
    # and wires the viewport scroll keys (when `keys:` is on and `ignore_keys` is
    # off): Up/Down (and, with `vi:`, `k`/`j`) by a line, `Ctrl-U`/`Ctrl-D` by a
    # half page, `PageUp`/`PageDown` (and `Ctrl-B`/`Ctrl-F`) by a full page,
    # `Home`/`End` to the top/bottom, and — with `vi:` — `g`/`G` to the
    # top/bottom. Paging/jump keys mirror `ScrollableBox#on_keypress`; only the
    # single-char `k`/`j`/`g`/`G` are `vi`-gated.
    module Interactive
      include NavKeys

      macro included
        @input = true
        @resizable = true
      end

      def initialize(*arg, **kwarg)
        super

        if @keys && !@ignore_keys
          on(Crysterm::Event::KeyPress) do |e|
            # Page scrolling uses the resolved `aheight`, not the raw `height`
            # property, so it works correctly even when `height` is a percentage
            # (e.g. `"100%"`) or unset.
            case nav_intent(e)
            when .backward?      then scroll(-1); request_render
            when .forward?       then scroll(1); request_render
            when .half_backward? then page_scroll(-aheight // 2, -1)
            when .half_forward?  then page_scroll(aheight // 2, 1)
            when .page_backward? then page_scroll(-aheight, -1)
            when .page_forward?  then page_scroll(aheight, 1)
            when .first?         then scroll_to 0; request_render
            when .last?          then scroll_to get_scroll_height; request_render
            end
          end
        end
      end

      # Scrolls by a page step and repaints; shared by Ctrl-U/D/B/F. *offs* is the
      # computed page offset; *dir* is the single-line fallback when *offs* rounds
      # to zero (a viewport only a line or two tall).
      private def page_scroll(offs : Int32, dir : Int32) : Nil
        scroll(offs == 0 ? dir : offs)
        request_render
      end
    end
  end
end
