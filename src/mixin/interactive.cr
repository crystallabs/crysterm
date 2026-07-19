require "./nav_keys"

module Crysterm
  module Mixin
    # The "is interactive" concern — a focusable widget that accepts keyboard
    # input and scrolls its viewport with the arrow/paging keys. Normally
    # obtained by subclassing `Widget::Input` (`Box` + this mixin); included
    # directly by a widget that must root in a different base.
    #
    # Sets the widget interactive (`@input`) and shrink-to-content
    # (`@shrink_to_fit`), and wires the viewport scroll keys (when `keys:` is on
    # and `ignore_keys` is off): Up/Down (and, with `vi_keys:`, `k`/`j`) by a line,
    # `Ctrl-U`/`Ctrl-D` by a half page, `PageUp`/`PageDown` (and
    # `Ctrl-B`/`Ctrl-F`) by a full page, `Home`/`End` to the top/bottom, and —
    # with `vi_keys:` — `g`/`G` to the top/bottom.
    module Interactive
      include NavKeys

      macro included
        @input = true
        @shrink_to_fit = true
      end

      def initialize(*arg, **kwarg)
        super

        if @keys && !@ignore_keys
          on(Crysterm::Event::KeyPress) do |e|
            # Stand down when the includer is consuming these keys itself.
            next unless viewer_scroll_keys?
            # Only the vertical-navigation keys are ours; anything else falls
            # through to ancestors untouched.
            intent = nav_intent(e)
            next if intent.none?
            # Page by `visible_content_rows`, not the raw `height` property, so a
            # bordered widget doesn't over-page. `half` is computed once so
            # Ctrl-U and Ctrl-D move symmetric amounts on odd-height widgets
            # (`-x // 2` would floor asymmetrically); at least one row.
            page = visible_content_rows
            half = Math.max(page // 2, 1)
            case intent
            when .backward?      then scroll(-1); request_render
            when .forward?       then scroll(1); request_render
            when .half_backward? then page_scroll(-half, -1)
            when .half_forward?  then page_scroll(half, 1)
            when .page_backward? then page_scroll(-page, -1)
            when .page_forward?  then page_scroll(page, 1)
            when .first?         then scroll_to 0; request_render
            when .last?          then scroll_to scroll_height; request_render
            end
            # Consume the handled key — don't also drive an ancestor.
            e.accept
          end
        end
      end

      # Whether this widget's viewport scroll keys (Up/Down/Ctrl-U/D/PageUp/Down/
      # Home/End) are currently live. True by default; overridden by an includer
      # that drives those keys itself, to avoid double-firing a scroll.
      def viewer_scroll_keys? : Bool
        true
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
