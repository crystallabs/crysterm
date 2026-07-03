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
            # Stand down when the includer is currently consuming these keys for
            # something else — e.g. a `Mixin::TextEditing` widget while it's
            # reading routes Up/Down/Ctrl-U/… to its editor and must not also
            # scroll the viewport (see `viewer_scroll_keys?`).
            next unless viewer_scroll_keys?
            # Page scrolling uses `visible_content_rows` (the actual scrollable
            # viewport, excluding borders and a shown horizontal bar's row) rather
            # than the raw `height` property, mirroring `ScrollableBox#on_keypress`
            # so a bordered widget doesn't over-page. `half` is computed once so
            # Ctrl-U and Ctrl-D move symmetric amounts on odd-height widgets
            # (`-x // 2` would floor asymmetrically); at least one row.
            page = visible_content_rows
            half = Math.max(page // 2, 1)
            case nav_intent(e)
            when .backward?      then scroll(-1); request_render
            when .forward?       then scroll(1); request_render
            when .half_backward? then page_scroll(-half, -1)
            when .half_forward?  then page_scroll(half, 1)
            when .page_backward? then page_scroll(-page, -1)
            when .page_forward?  then page_scroll(page, 1)
            when .first?         then scroll_to 0; request_render
            when .last?          then scroll_to get_scroll_height; request_render
            end
          end
        end
      end

      # Whether this widget's viewport scroll keys (Up/Down/Ctrl-U/D/PageUp/Down/
      # Home/End) are currently live. True by default; `Mixin::TextEditing`
      # overrides it to stand down while reading, so those keys drive the editor
      # instead of double-firing a scroll.
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
