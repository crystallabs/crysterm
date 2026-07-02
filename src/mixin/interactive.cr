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
      macro included
        @input = true
        @resizable = true
      end

      def initialize(*arg, **kwarg)
        super

        if @keys && !@ignore_keys
          on(Crysterm::Event::KeyPress) do |e|
            key = e.key
            ch = e.char

            if key == Tput::Key::Up || (@vi && ch == 'k')
              scroll(-1)
              request_render
              next
            end
            if key == Tput::Key::Down || (@vi && ch == 'j')
              scroll(1)
              request_render
              next
            end

            # Paging and jump-to-edge are not vi-only (matching
            # `ScrollableBox#on_keypress`). Page scrolling uses the resolved
            # `aheight`, not the raw `height` property, so it works correctly even
            # when `height` is a percentage (e.g. `"100%"`) or unset.
            case key
            when Tput::Key::CtrlU
              page_scroll(-aheight // 2, -1)
              next
            when Tput::Key::CtrlD
              page_scroll(aheight // 2, 1)
              next
            when Tput::Key::PageUp, Tput::Key::CtrlB
              page_scroll(-aheight, -1)
              next
            when Tput::Key::PageDown, Tput::Key::CtrlF
              page_scroll(aheight, 1)
              next
            when Tput::Key::Home
              scroll_to 0
              request_render
              next
            when Tput::Key::End
              scroll_to get_scroll_height
              request_render
              next
            end

            # The single-char jump keys stay vi-gated per the docstring.
            if @vi
              case ch
              when 'g'
                scroll_to 0
                request_render
                next
              when 'G'
                scroll_to get_scroll_height
                request_render
                next
              end
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
