module Crysterm
  class Widget
    # Blank space in a `Layout::Box` — the widget behind
    # `Layout::Box#add_spacing`/`#add_stretch` (cf. Qt's `QSpacerItem`, which
    # `QBoxLayout::addSpacing`/`addStretch` insert).
    #
    # Unlike Qt — where a spacer is a layout *item*, not a widget — a Crysterm
    # layout arranges real children, so a spacer must be one. It is therefore
    # deliberately **arranged but inert**:
    #
    # * **Occupies space** — neither `layout_excluded?` nor `layout_chrome?`,
    #   so every engine's `each_arrangeable` walk gives it a slot: it consumes
    #   main-axis cells (and a `spacing` gap) exactly like a real child.
    # * **Never focusable** — the constructor pins `focus_policy` to `None`
    #   (which also keeps `keys`/`input` off), so it is never registered in the
    #   window's keyable list and Tab/Shift+Tab traversal cannot land on it.
    # * **Invisible to hit-testing** — `#wants_mouse?` is hard-wired `false`
    #   (even if a stray mouse handler gets attached), so `Window#widget_at`
    #   over the gap falls through to the container underneath.
    # * **Paints nothing** — the default inline style is `fill: false` (no
    #   border, no background sweep), so whatever is underneath shows through;
    #   the spacer contributes geometry only. An explicit `style:` overrides
    #   this for the rare debug-visualization case.
    #
    # It carries either a **fixed size** or a **stretch factor**:
    #
    # * `Spacer.new(5)` — a fixed spacer: both `width` and `height` are set to
    #   the size (Qt's `QSpacerItem(w, h)` shape), so whichever axis a box
    #   treats as main, the spacer holds exactly that many cells there. The
    #   cross-axis copy is inert — the spacer is invisible and untouchable.
    # * `Spacer.stretch(2)` — a growing spacer: no explicit size, plus a
    #   `Layout::Box::Hint` carrying the factor, so it takes its share of the
    #   leftover through the box's normal grow distribution (`Hint#stretch`),
    #   not a parallel mechanism.
    class Spacer < Widget
      def initialize(size : Int32? = nil, style : Style? = nil, **widget)
        super(**widget, width: size, height: size, style: style || Style.new(fill: false))
        # Through the setter, so the policy is *explicit* (`accepts_tab_focus?`
        # becomes a definitive `false`) rather than merely derived from the
        # legacy flags — and stays `None` even if a stylesheet or caller
        # key-enables the widget by accident.
        self.focus_policy = FocusPolicy::None
      end

      # A growing spacer taking *factor* shares of the box's leftover space —
      # Qt's `QBoxLayout::addStretch(factor)` payload. Routed through the
      # box engine's existing grow distribution via `Layout::Box::Hint`.
      def self.stretch(factor : Int32 = 1, **widget) : Spacer
        sp = new(**widget)
        sp.layout_hint = Layout::Box::Hint.new(stretch: factor)
        sp
      end

      # Empty space takes no mouse events, ever: `Window#widget_at` skips it
      # and reports whatever lies underneath (typically the container).
      def wants_mouse?
        false
      end

      # A fixed spacer's natural size is its declared size; a stretch spacer
      # has none (0×0) — it exists to absorb leftover space, not to claim any.
      def size_hint : Size
        w = @width
        h = @height
        Size.new (w.is_a?(Int32) ? w : 0), (h.is_a?(Int32) ? h : 0)
      end
    end
  end
end
