module Crysterm
  module Mixin
    # The "is interactive" concern — a focusable widget that accepts keyboard
    # input and scrolls its viewport with the arrow/paging keys.
    #
    # Qt has no single base for this: it distributes focus/key handling per
    # widget. Crysterm centralizes it in `Widget::Input` (`Box` + this mixin).
    # But because Crystal is single-inheritance, a widget that must root in a
    # *different* Qt base — e.g. `PlainTextEdit`, whose Qt ancestor is
    # `QAbstractScrollArea`, not an input base — cannot also be an `Input`. Those
    # widgets `include Mixin::Interactive` directly instead, getting the same
    # behavior without giving up their Qt-faithful lineage.
    #
    # It sets the widget interactive (`@input`) and freely-resizable
    # (`@resizable`), and wires the viewport scroll keys (when `keys:` is on and
    # `ignore_keys` is off): Up/Down (and, with `vi:`, `k`/`j`) by a line,
    # `Ctrl-U`/`Ctrl-D` by a half page, `Ctrl-B`/`Ctrl-F` by a full page, and
    # `g`/`G` to the top/bottom.
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

            if @vi
              # Page scrolling is sized off the *resolved* `aheight`, not the raw
              # `height` property. The old code gated each branch on
              # `height.is_a? Int`, so a widget whose height was a percentage
              # (`"100%"` — the common case for a scrollable pane) or left unset
              # silently dropped all four keys: line-scroll (Up/Down) worked but
              # half-/full-page (Ctrl-U/D/B/F) did nothing. `aheight` always
              # resolves to the actual rendered Int height, so the page step is
              # correct regardless of how the height was specified.
              case key
              when Tput::Key::CtrlU
                page_scroll(-aheight // 2, -1)
                next
              when Tput::Key::CtrlD
                page_scroll(aheight // 2, 1)
                next
              when Tput::Key::CtrlB
                page_scroll(-aheight, -1)
                next
              when Tput::Key::CtrlF
                page_scroll(aheight, 1)
                next
              end

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

      # Scrolls by a page step, then repaints — the body the four half-/full-page
      # keys (Ctrl-U/D/B/F) otherwise repeat. *offs* is the computed page offset;
      # *dir* (`-1`/`+1`) is the single-line fallback used when *offs* rounds to
      # zero (a viewport only a line or two tall, where `aheight // 2` is 0).
      private def page_scroll(offs : Int32, dir : Int32) : Nil
        scroll(offs == 0 ? dir : offs)
        request_render
      end
    end
  end
end
