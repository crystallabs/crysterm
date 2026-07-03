module Crysterm
  module Mixin
    module Style
      # Current state of Widget

      # ameba:disable Lint/UselessAssign
      Crystallabs::Helpers::Enums.enum_property state : WidgetState = WidgetState::Normal

      # Re-wraps the generated `state=` setters so a state transition invalidates
      # styling and the cascade re-runs (needed for ancestor-state rules like
      # `Form:focus Button`). Guarded on actual change to avoid needless restyles
      # (e.g. lists re-asserting an item's state every frame).
      def state=(value : WidgetState) : WidgetState
        return value if @state == value
        # Snapshot the old state's animatable style values so a CSS `transition`
        # can tween to the new state's values.
        prev = transition_from
        @state = value
        # The resolved style depends on the state (per-state lookup + highlight
        # fallbacks), so drop the frame-memoized resolution. Must run AFTER the
        # `transition_from` snapshot above, which resolves (and re-caches) the
        # OLD state's style.
        invalidate_frame_style
        # The style swap is in-place and invisible to the tracked geometry
        # setters, so flag damage explicitly — otherwise the optimized render
        # leaves the previous state's pixels behind (a stale highlight).
        mark_dirty
        window?.try do |scr|
          if scr.css_dynamic_state?
            scr.restyle_subtree self # ancestor-state rules exist: recascade
          else
            scr.css_node_changed self # otherwise keep cached document in sync
          end
        end
        prev.try { |p| apply_style_transitions p }
        value
      end

      def state=(value : ::Crystallabs::Helpers::Enums::Shorthands)
        self.state = ::Crystallabs::Helpers::Enums.from(WidgetState, value)
      end

      # List of styles corresponding to different widget states.
      #
      # Only one style, `normal` is initialized by default, others default to it if `nil`.
      getter styles : ::Crysterm::Styles = ::Crysterm::Styles.default

      # :ditto:
      def styles=(styles : ::Crysterm::Styles) : ::Crysterm::Styles
        invalidate_frame_style
        @styles = styles
      end

      # Pristine, pre-CSS snapshot of `#styles`, captured lazily on first cascade
      # use. Each cascade rebuilds from a fresh dup of this snapshot, so removed
      # rules and changed inherited values don't linger.
      @css_base_styles : ::Crysterm::Styles?

      # :ditto:
      def css_base_styles : ::Crysterm::Styles
        @css_base_styles ||= begin
          snap = styles.deep_dup
          # The programmatic floor border must never seed the cascade — a
          # stylesheet owns the border entirely. Drop it so a theme without a
          # border rule doesn't inherit the floor default.
          snap.normal.border = false if floor_border_installed?
          snap
        end
      end

      # Drops the pristine snapshot so it is recaptured from the current `#styles`
      # on the next cascade. Call after deliberately changing a widget's
      # programmatic default styles.
      def reset_css_base_styles : Nil
        @css_base_styles = nil
      end

      # User may set specific style for this widget
      def style=(style : ::Crysterm::Style?)
        invalidate_frame_style
        @style = style
      end

      # The raw inline style (the `@style` override), before any CSS folding.
      # The CSS cascade reads this to fold inline declarations into the computed
      # per-state `@styles` at its own tier.
      def css_inline_style : ::Crysterm::Style?
        @style
      end

      # Set by the CSS cascade once it has computed this widget's `@styles`
      # (folding in any inline `@style`). When set, `#style` returns the computed
      # per-state style rather than short-circuiting to the raw inline `@style`,
      # so author `!important` rules can outrank inline.
      getter? css_styled : Bool = false

      # :ditto: — the cascade flips this around every (re)apply, so it doubles
      # as the cascade's invalidation hook for the frame-memoized style.
      def css_styled=(value : Bool) : Bool
        invalidate_frame_style
        @css_styled = value
      end

      # The raw, persistent backing `Style` for the current state — `#style`
      # without the unstyled-floor highlight fallbacks.
      #
      # Persistent per-state fields — notably `visible` (toggled by `#hide`/
      # `#show`) — MUST be read/written through here, never via `#style`: at the
      # floor, `#style` layers reverse-video on `:focused`/`:selected` via a
      # transient `#dup`, so a write through it would be lost (a focused `Button`
      # could never be hidden).
      def state_style : ::Crysterm::Style
        unless @css_styled
          @style.try { |style| return style }
        end
        per_state_style
      end

      # The backing `Style` for the current `@state`, with no inline override and
      # no floor highlight fallbacks — the single source of the state→style map
      # shared by `#state_style` and `#style`.
      private def per_state_style : ::Crysterm::Style
        @styles.for_state(@state)
      end

      # The resolved `Style` for the current frame, memoized per widget per
      # window frame. Resolution (`#resolve_style`: floor-border sync, per-state
      # dispatch, highlight fallbacks — worst case a heap `Style#dup` per call
      # for a focused/selected floor widget) runs ~15-25× per widget per frame
      # otherwise, and was the hottest render leaf.
      @_frame_style : ::Crysterm::Style?

      # `Window#renders` value `@_frame_style` was resolved at; a stamp mismatch
      # (new frame) re-resolves, so cross-frame mutations of `@styles`' contents
      # are picked up without any explicit invalidation.
      @_frame_style_stamp : Int32 = -1

      # Drops the frame-memoized style resolution (and the insets derived from
      # it — see `Widget#frame_insets`). Called by every same-frame-visible
      # style change: `#state=`, `#style=`, `#styles=`, and the CSS cascade via
      # `#css_styled=`. Rendering is single-fiber, so these hooks plus the
      # per-frame stamp cover all reachable staleness.
      def invalidate_frame_style : Nil
        @_frame_style = nil
        @_frame_insets = nil
      end

      # If specific style is not set, it will depend on current state
      def style : ::Crysterm::Style
        if (fs = @_frame_style) && (scr = window?) && @_frame_style_stamp == scr.renders
          return fs
        end
        st = resolve_style
        # The insets cache is derived from the resolved style, so its validity
        # is exactly "the frame cache was not refreshed since" — reset together.
        @_frame_insets = nil
        if scr = window?
          @_frame_style = st
          @_frame_style_stamp = scr.renders
        end
        st
      end

      # Uncached style resolution — the former body of `#style`.
      private def resolve_style : ::Crysterm::Style
        # When CSS has computed this widget's styles, inline `@style` is already
        # folded in, so use the per-state style. Otherwise inline `@style` wins
        # wholesale, and the floor border is installed lazily here (the one
        # render-only step `#state_style` omits).
        unless @css_styled
          # Skip `ensure_floor_border` when an inline `@style` will win wholesale
          # (it bypasses `@styles.normal`, so the border would never be observed
          # anyway). `#style` runs ~10x per widget per frame, and the virtual
          # dispatch + per-state lookups in `ensure_floor_border` were the hottest
          # render leaf — pure waste for inline-styled widgets.
          if style = @style
            return style
          end
          ensure_floor_border
        end

        # Decorate only the per-state styles with the unstyled-floor highlight
        # fallbacks; an inline `@style` (returned above) is never touched. These
        # fallbacks are no-ops under any theme (`css_styled`).
        st = per_state_style
        case @state
        when .focused?  then focus_highlight_fallback st
        when .selected? then selection_highlight_fallback st
        else                 st
        end
      end

      # Whether this widget should carry a default structural border at the
      # unstyled floor (no CSS active). Overlays (Menu, popups, dialogs,
      # tooltips, splash screens) override to `true` to separate from content
      # when there's no color to do it; plain content widgets don't. May be
      # dynamic: a `DockWidget` returns `true` only while floating (docked panes
      # stay borderless, separated by layout instead) — `#ensure_floor_border`
      # installs and removes to track such changes. Any active theme makes the
      # widget `css_styled`, putting the cascade fully in control (free to set
      # any border, including none, e.g. qdarkstyle's `QMenu { border: 0 }`).
      def floor_border? : Bool
        false
      end

      # Which floor border to install when unstyled, as a value `Border.from`
      # accepts: `false` (none), `true` (all four sides), or a `Border` selecting
      # specific sides. Defaults to a full border iff `#floor_border?`. A
      # `DockWidget` overrides this to a full frame while floating but only the
      # edge facing the central content while docked.
      def floor_border_value
        floor_border? ? true : false
      end

      # Whether this widget should indicate focus via reverse-video at the
      # unstyled floor (no CSS active). Defaults to `false`: a large focusable
      # widget (container, list, text editor) must not invert its whole viewport
      # on focus. The small button family (`Button`/`CheckBox`/`RadioButton` —
      # see `AbstractButton`) overrides this to `true` so a focused control reads
      # on any terminal with no theme.
      def floor_focus_reverse? : Bool
        false
      end

      # The `{left, top, right, bottom}` of the floor border this widget last
      # applied to `styles.normal`, or `nil` before it ever applied one. Drives
      # change detection (re-assign only when the wanted sides change) and the
      # cascade-base strip (see `#css_base_styles`).
      @floor_border_applied : Tuple(Int32, Int32, Int32, Int32)? = nil

      # Whether a border was already set explicitly (inline style / author CSS)
      # before the floor logic first ran. Memoized on first use — distinct from
      # `@floor_border_applied`, which tracks the floor's own border. When true,
      # that explicit choice (including `border: false`) owns the border for good.
      @floor_border_user_set : Bool? = nil

      # Whether a floor border is currently installed (any side). Used by
      # `#css_base_styles` to strip it from the cascade snapshot.
      private def floor_border_installed? : Bool
        (s = @floor_border_applied) ? (s != {0, 0, 0, 0}) : false
      end

      # Syncs the structural floor border on `styles.normal` to what the widget
      # currently wants (`#floor_border_value`), reached from `#style` only while
      # no CSS is active. Installs and removes (and updates sides) so a dynamic
      # floor border (e.g. a `DockWidget` floating/re-docking) stays in lock-step.
      # Set in place (not on a dup) so it survives `hide`/`show`, and excluded
      # from the cascade base (see `#css_base_styles`). An explicit author/inline
      # border is honored — including `border: false`.
      private def ensure_floor_border : Nil
        normal = @styles.normal
        # Capture once whether a border was explicitly set before the floor ever
        # touched it; that choice then wins for good. (`||=` can't memoize
        # `false`, hence the explicit nil check — must run before this method
        # sets the border below, which flips `specified?` true.)
        if @floor_border_user_set.nil?
          @floor_border_user_set = normal.specified?(:border)
        end
        return if @floor_border_user_set

        val = floor_border_value
        # Resolve wanted sides without constructing a `Border` for the common
        # `Bool` floor values — `#ensure_floor_border` runs on every render of an
        # unstyled widget, and allocating a throwaway `Border` just to read its
        # sides back was ~2 KB/widget/frame of garbage. Non-`Bool` values still
        # resolve through `Border.from` as before; out-of-sync changes still
        # build the `Border` needed for the actual assignment.
        if quick = floor_border_quick_sides(val)
          return if @floor_border_applied == quick # already in sync — no allocation
          normal.border = ::Crysterm::Border.from(val)
          @floor_border_applied = quick
        else
          want = ::Crysterm::Border.from(val)
          sides = {want.left, want.top, want.right, want.bottom}
          return if @floor_border_applied == sides # already in sync
          normal.border = want
          @floor_border_applied = sides
        end
      end

      # The `{left, top, right, bottom}` a floor-border value resolves to for the
      # two `Bool` cases, computed without allocating a `Border`; `nil` for any
      # other value (resolved via `Border.from` by the caller). Mirrors
      # `Border.from(true)`/`Border.from(false)`.
      private def floor_border_quick_sides(value) : Tuple(Int32, Int32, Int32, Int32)?
        case value
        when true       then {1, 1, 1, 1}
        when false, nil then {0, 0, 0, 0}
        else                 nil
        end
      end

      # At the unstyled floor, a `:selected` widget whose style carries no
      # visible distinction (no fg/bg/reverse — e.g. a `MenuBar`/`ToolBar`/
      # `ListBar` item falling back to `normal`) is shown via reverse-video, so
      # the active entry reads with no theme.
      private def selection_highlight_fallback(st : ::Crysterm::Style) : ::Crysterm::Style
        reverse_highlight_fallback st
      end

      # Focus counterpart of `#selection_highlight_fallback`, gated on
      # `#floor_focus_reverse?` so only opted-in small controls invert. Widgets
      # that don't opt in (containers, lists, text editors) are returned
      # untouched, so focus never wholesale-inverts a large viewport.
      private def focus_highlight_fallback(st : ::Crysterm::Style) : ::Crysterm::Style
        return st unless floor_focus_reverse?
        reverse_highlight_fallback st
      end

      # Shared core of `#selection_highlight_fallback`/`#focus_highlight_fallback`:
      # at the unstyled floor, a state style with no visible distinction of its
      # own (no fg/bg/reverse) is shown via reverse-video; otherwise *st* is
      # returned untouched. Delegates to `Style#with_reverse_fallback`, which
      # dups before toggling so a shared style is never mutated in place.
      private def reverse_highlight_fallback(st : ::Crysterm::Style) : ::Crysterm::Style
        return st if @css_styled
        st.with_reverse_fallback
      end

      # Version with keeping @state and @style in sync:
      # getter state = WidgetState::Normal
      # # :ditto:
      # def state=(state : WidgetState)
      #  @state = state
      #  @style = case state
      #           in .normal?
      #             @styles.normal
      #           in .focused?
      #             @styles.focused
      #           in .selected?
      #             @styles.selected
      #           in .hovered?
      #             @styles.hovered
      #           in .blurred?
      #             @styles.blurred
      #           end
      # end
      # Current style applied during rendering, kept in sync with `Widget#state`.
      # A reference, not a copy — editing `style` edits whatever it points to.
      # If a widget is e.g. `focused` but has no focus style defined, it renders
      # `normal`; editing `style` then actually edits `normal`, not `focused`.
      # property style : Style # = Style.new # Placeholder

    end
  end
end
