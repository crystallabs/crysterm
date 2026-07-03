module Crysterm
  class Widget
    # Box-drawing and marker glyphs shared by more than one widget, kept in one
    # place so the literal characters aren't re-typed per widget (where copies
    # had drifted or risked drifting). Defined on `Widget` so any widget subclass
    # reaches them unqualified via lexical scope.

    # Vertical box-drawing line (`│`) — used for a vertical `Line` and for the
    # divider of a *horizontal* `Splitter` (side-by-side panes are separated by
    # vertical bars).
    LINE_VERTICAL = '│'

    # Horizontal box-drawing line (`─`) — used for a horizontal `Line` and for
    # the divider of a *vertical* `Splitter`.
    LINE_HORIZONTAL = '─'

    # Disclosure markers drawn before an expandable row (`Tree` nodes,
    # `ToolBox` section headers).
    MARKER_EXPANDED  = '▾' # an open/expanded node
    MARKER_COLLAPSED = '▸' # a closed/collapsed node
  end
end
