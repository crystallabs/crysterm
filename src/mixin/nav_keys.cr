module Crysterm
  module Mixin
    # The vertical navigation key-map, single-sourced.
    #
    # `Mixin::Interactive` (viewport scrolling) and `Mixin::ItemView`
    # (selection movement) both answer the same question — *which physical key
    # means "one back", "a page forward", "jump to the end"?* — and then map that
    # intent onto a different action (`scroll`/`page_scroll`/`scroll_to` vs
    # `up`/`down`/`move`/`selekt`). The *classification* is identical; only the
    # *action* differs. Keeping the key table in one place is exactly the
    # anti-drift point of the formalization work: a key added or rebound here
    # reaches both families at once, instead of one silently keeping the old map.
    #
    # `ActionBar` is intentionally NOT a member: it navigates *horizontally*
    # (Left/Right/Tab/ShiftTab, none of the keys below) and its vi bindings
    # conflict with these (`k` activates a command there, but means "one back"
    # here), so a shared classifier would have to be parameterized by orientation
    # and a second vi-map — indirection, not dedup.
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
      # caller can fall through to its own (widget-specific) handling. The
      # paging/jump keys are not vi-gated (matching `ScrollableBox#on_keypress`);
      # only `k`/`j`/`g`/`G` are.
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
