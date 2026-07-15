module Crysterm
  module Mixin
    # The vertical navigation key-map, single-sourced: it classifies a key into
    # an intent, leaving the including type to map that intent onto its own
    # action (scrolling a viewport, moving a selection cursor, …).
    #
    # The including type must provide `@vi`.
    module NavKeys
      # A vertical-navigation intent, orientation- and action-neutral so both a
      # scroller and a selection cursor can consume it. "Backward" is toward the
      # first item / top of the viewport; "Forward" toward the last / bottom.
      enum NavIntent
        None
        Backward     # one line/item back      (Up, vi `k`)
        Forward      # one line/item forward    (Down, vi `j`)
        HalfBackward # half a page back         (Ctrl-U)
        HalfForward  # half a page forward      (Ctrl-D)
        PageBackward # a full page back         (PageUp, Ctrl-B)
        PageForward  # a full page forward      (PageDown, Ctrl-F)
        First        # jump to the first        (Home, vi `g`)
        Last         # jump to the last         (End,  vi `G`)
      end

      # Classifies a `KeyPress` into a `NavIntent`, honoring `@vi` for the
      # single-char bindings. Returns `NavIntent::None` for any other key, so the
      # caller can fall through to its own handling. Only `k`/`j`/`g`/`G` are
      # vi-gated; the paging/jump keys are always live.
      def nav_intent(e) : NavIntent
        key = e.key
        ch = e.char
        case
        when key == ::Tput::Key::Up || (@vi && ch == 'k')
          NavIntent::Backward
        when key == ::Tput::Key::Down || (@vi && ch == 'j')
          NavIntent::Forward
        when key == ::Tput::Key::CtrlU
          NavIntent::HalfBackward
        when key == ::Tput::Key::CtrlD
          NavIntent::HalfForward
        when key == ::Tput::Key::PageUp || key == ::Tput::Key::CtrlB
          NavIntent::PageBackward
        when key == ::Tput::Key::PageDown || key == ::Tput::Key::CtrlF
          NavIntent::PageForward
        when key == ::Tput::Key::Home || (@vi && ch == 'g')
          NavIntent::First
        when key == ::Tput::Key::End || (@vi && ch == 'G')
          NavIntent::Last
        else
          NavIntent::None
        end
      end
    end
  end
end
