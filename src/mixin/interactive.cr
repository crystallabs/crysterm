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
              # XXX remove all those protections for height being Int
              case key
              when Tput::Key::CtrlU
                height.try do |h|
                  next unless h.is_a? Int
                  offs = -h // 2
                  scroll offs == 0 ? -1 : offs
                  request_render
                end
                next
              when Tput::Key::CtrlD
                height.try do |h|
                  next unless h.is_a? Int
                  offs = h // 2
                  scroll offs == 0 ? 1 : offs
                  request_render
                end
                next
              when Tput::Key::CtrlB
                height.try do |h|
                  next unless h.is_a? Int
                  offs = -h
                  scroll offs == 0 ? -1 : offs
                  request_render
                end
                next
              when Tput::Key::CtrlF
                height.try do |h|
                  next unless h.is_a? Int
                  offs = h
                  scroll offs == 0 ? 1 : offs
                  request_render
                end
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
    end
  end
end
