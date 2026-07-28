module Crysterm
  module Mixin
    # The vertical navigation key-map, single-sourced: it classifies a key into
    # an intent, leaving the including type to map that intent onto its own
    # action (scrolling a viewport, moving a selection cursor, …).
    #
    # The including type must provide `@vi_keys`.
    module NavKeys
      # A vertical-navigation intent, orientation- and action-neutral so both a
      # scroller and a selection cursor can consume it. "Backward" is toward the
      # first item / top of the viewport; "Forward" toward the last / bottom.
      enum NavIntent
        None
        Backward     # one line/item back      (Up, vi_keys `k`)
        Forward      # one line/item forward    (Down, vi_keys `j`)
        HalfBackward # half a page back         (Ctrl-U)
        HalfForward  # half a page forward      (Ctrl-D)
        PageBackward # a full page back         (PageUp, Ctrl-B)
        PageForward  # a full page forward      (PageDown, Ctrl-F)
        First        # jump to the first        (Home, vi_keys `g`)
        Last         # jump to the last         (End,  vi_keys `G`)
      end

      # Classifies a `KeyPress` into a `NavIntent`, honoring `@vi_keys` for the
      # single-char bindings. Returns `NavIntent::None` for any other key, so the
      # caller can fall through to its own handling. Only `k`/`j`/`g`/`G` are
      # vi_keys-gated; the paging/jump keys are always live.
      def nav_intent(e : ::Crysterm::Event::KeyPress) : NavIntent
        key = e.key
        ch = e.char
        case
        when key == ::Tput::Key::Up || (@vi_keys && ch == 'k')
          NavIntent::Backward
        when key == ::Tput::Key::Down || (@vi_keys && ch == 'j')
          NavIntent::Forward
        when key == ::Tput::Key::CtrlU
          NavIntent::HalfBackward
        when key == ::Tput::Key::CtrlD
          NavIntent::HalfForward
        when key == ::Tput::Key::PageUp || key == ::Tput::Key::CtrlB
          NavIntent::PageBackward
        when key == ::Tput::Key::PageDown || key == ::Tput::Key::CtrlF
          NavIntent::PageForward
        when key == ::Tput::Key::Home || (@vi_keys && ch == 'g')
          NavIntent::First
        when key == ::Tput::Key::End || (@vi_keys && ch == 'G')
          NavIntent::Last
        else
          NavIntent::None
        end
      end

      # The nearest *selectable* index to *from* within `0...size`, stepping in
      # *dir* over separators (the block returns whether an index is a
      # separator). When the step runs off the end while still on a separator, it
      # rescans the opposite way, so the result is never a separator. Returns
      # `nil` only when *size* is 0 or every index is a separator.
      #
      # Index-only navigation core, so the "never land the cursor on a separator"
      # edge semantics live once. A module method so any widget — includer or
      # not — can reuse it (`Mixin::ItemView`, `Mixin::ActionBar`, `Widget::Menu`).
      def self.nearest_selectable(size : Int32, from : Int32, dir : Int32, & : Int32 -> Bool) : Int32?
        return if size == 0
        i = from.clamp(0, size - 1)
        size.times do
          break unless yield i
          ni = i + dir
          break if ni < 0 || ni >= size
          i = ni
        end
        if yield i
          # Landed on a separator at the array boundary: rescan the opposite way
          # so the highlight never rests on one.
          j = i
          while (j -= dir) >= 0 && j < size
            return j unless yield j
          end
          return
        end
        i
      end
    end
  end
end
