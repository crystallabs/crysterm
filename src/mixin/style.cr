module Crysterm
  module Mixin
    module Style
      # Current state of Widget

      # ameba:disable Lint/UselessAssign
      Crystallabs::Helpers::Enums.enum_property state : WidgetState = WidgetState::Normal

      # Re-wrap the generated `state=` setters so that, when an active stylesheet
      # has ancestor-state rules (`Form:focus Button`), a state transition
      # invalidates styling and the cascade re-runs on the next render. Guarded
      # on an actual change to avoid needless restyles (e.g. lists re-asserting an
      # item's state every frame).
      def state=(value : WidgetState) : WidgetState
        return value if @state == value
        # Snapshot the animatable values of the *old* state's style so any CSS
        # `transition` can tween from them to the new state's values.
        prev = transition_from
        @state = value
        # A state change selects a different style (e.g. `styles.selected` vs
        # `styles.normal`), so the widget must be repainted. The tracked geometry
        # setters can't see this in-place style swap, so flag it for damage
        # tracking explicitly; otherwise the optimized render leaves the previous
        # state's pixels in the buffer (a stale highlight). Guarded above on an
        # actual change, so a list re-asserting the same state every frame is free.
        mark_dirty
        screen?.try do |scr|
          if scr.css_dynamic_state?
            scr.restyle_subtree self # ancestor-state rules exist: recascade
          else
            scr.css_node_changed self # otherwise just keep the cached document in sync
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
      property styles : ::Crysterm::Styles = ::Crysterm::Styles.default

      # Pristine, pre-CSS snapshot of `#styles`, captured lazily the first time
      # the cascade asks for it. Each cascade rebuilds the computed styles from a
      # fresh dup of this snapshot, so removed rules and changed inherited values
      # don't linger (the cascade is otherwise non-destructive — it builds on the
      # *current* styles).
      @css_base_styles : ::Crysterm::Styles?

      # :ditto:
      def css_base_styles : ::Crysterm::Styles
        @css_base_styles ||= begin
          snap = styles.deep_dup
          # The programmatic floor border (installed by `#ensure_floor_border` for
          # overlays) must never seed the cascade: a stylesheet owns the border
          # entirely. Drop it from the pristine snapshot so a theme *without* a
          # border rule doesn't inherit the floor default (no themed regression),
          # while a theme that does set one still wins.
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
      setter style : ::Crysterm::Style?

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
      property? css_styled : Bool = false

      # The raw, *persistent* backing `Style` for the current state — `#style`
      # without the unstyled-floor highlight fallbacks. Inline `@style` (when not
      # `css_styled`) still wins wholesale, exactly as `#style` resolves it.
      #
      # Persistent per-state fields — notably `visible` (toggled by `#hide`/
      # `#show`) — MUST be read and written through here, never via `#style`: at
      # the floor `#style` layers reverse-video on `:focused`/`:selected` by
      # returning a transient `#dup`, so a write through it lands on a throwaway
      # object and is lost (concretely: a focused `Button` could never be hidden).
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

      # If specific style is not set, it will depend on current state
      def style : ::Crysterm::Style
        # When CSS has computed this widget's styles, the inline `@style` has
        # already been folded into them at the right cascade tier, so use the
        # per-state style. Otherwise inline `@style` (if any) wins wholesale — and
        # the floor border is installed lazily here, the one render-only step
        # `#state_style` deliberately omits.
        unless @css_styled
          ensure_floor_border
          @style.try { |style| return style }
        end

        # Decorate only the per-state styles with the unstyled-floor highlight
        # fallbacks (an inline `@style`, returned above, is never touched). The
        # fallbacks are no-ops under any theme (`css_styled`), so this is the same
        # cascade-computed style there.
        st = per_state_style
        case @state
        when .focused?  then focus_highlight_fallback st
        when .selected? then selection_highlight_fallback st
        else                 st
        end
      end

      # Whether this widget should carry a default structural border at the
      # unstyled floor (no CSS active). Overlays (Menu, popups, dialogs,
      # tooltips, splash screens) override this to `true` so they separate from
      # content when there is no color to do it; plain content widgets do not.
      # May be *dynamic*: a `DockWidget` returns `true` only while floating, so a
      # detached pane gets a frame to read against the content it covers while a
      # docked one (separated by layout) stays borderless — `#ensure_floor_border`
      # installs *and* removes to track such changes. The border is purely a
      # programmatic *floor* default — any active theme makes the widget
      # `css_styled`, so the cascade is then fully in control and free to set any
      # border, including none (e.g. qdarkstyle's `QMenu { border: 0 }`).
      def floor_border? : Bool
        false
      end

      # *Which* floor border to install when unstyled, as a value `Border.from`
      # accepts: `false` (none), `true` (all four sides), or a `Border` selecting
      # specific sides. Defaults to a full border iff `#floor_border?`. A
      # `DockWidget` overrides this to a full frame while floating but only the
      # single edge facing the central content while docked, so a docked pane is
      # separated from the content it abuts without boxing in the whole panel.
      def floor_border_value
        floor_border? ? true : false
      end

      # Whether this widget should indicate *focus* via reverse-video at the
      # unstyled floor (no CSS active). Defaults to `false`: a large focusable
      # widget (container, list, text editor) must not invert its whole viewport
      # on focus. The small button family (`Button`/`CheckBox`/`RadioButton` —
      # see `AbstractButton`) overrides this to `true` so a focused control reads
      # on any terminal with no theme. Like `#floor_border?`, this is purely a
      # programmatic *floor* default — any active theme makes the widget
      # `css_styled`, so the cascade is then fully in control of focus styling.
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
      # `@floor_border_applied`, which tracks the *floor's own* border. When true,
      # that explicit choice (including an explicit `border: false`) owns the
      # border and the floor never touches it.
      @floor_border_user_set : Bool? = nil

      # Whether a floor border is currently installed (any side). Used by
      # `#css_base_styles` to strip it from the cascade snapshot.
      private def floor_border_installed? : Bool
        (s = @floor_border_applied) ? (s != {0, 0, 0, 0}) : false
      end

      # Syncs the structural *floor* border on `styles.normal` to what the widget
      # currently wants (`#floor_border_value`), reached from `#style` only while
      # no CSS is active. Both **installs and removes** (and updates which sides),
      # so a dynamic floor border (e.g. a `DockWidget` switching between a full
      # frame and a single content-facing edge as it floats/re-docks) stays in
      # lock-step. The border is set *in place* (not on a dup) so it survives
      # `hide`/`show`, which toggle `visible` on this very style, and is excluded
      # from the cascade base (see `#css_base_styles`) so a theme stays in full
      # control. An explicit author/inline border is honored — including
      # `border: false`.
      private def ensure_floor_border : Nil
        normal = @styles.normal
        # Capture once whether a border was explicitly set before the floor ever
        # touched it; that author/user choice then wins for good. (`||=` can't
        # memoize a `false`, hence the explicit nil check.) After this method sets
        # the border below, `specified?` flips true, so the memo must be taken
        # first — and only once.
        if @floor_border_user_set.nil?
          @floor_border_user_set = normal.specified?(:border)
        end
        return if @floor_border_user_set

        want = ::Crysterm::Border.from(floor_border_value)
        sides = {want.left, want.top, want.right, want.bottom}
        return if @floor_border_applied == sides # already in sync
        normal.border = want
        @floor_border_applied = sides
      end

      # At the unstyled floor (no CSS computed this widget — `@css_styled` is
      # false), a `:selected` widget whose selected style carries no visible
      # distinction of its own (no fg/bg/reverse — e.g. a `MenuBar`/`ToolBar`/
      # `ListBar` item lazily falling back to `normal`) is shown via reverse-video,
      # so the active entry reads on any terminal with no theme. Under any theme
      # the widget is `css_styled` and this returns the cascade-computed style
      # untouched; a `#dup` is taken before toggling so a shared style is never
      # mutated in place.
      private def selection_highlight_fallback(st : ::Crysterm::Style) : ::Crysterm::Style
        return st if @css_styled || st.specified?(:fg) || st.specified?(:bg) || st.reverse?
        st = st.dup
        st.reverse = true
        st
      end

      # Focus counterpart of `#selection_highlight_fallback`, gated additionally
      # on `#floor_focus_reverse?` so only the opted-in small controls invert. At
      # the unstyled floor (`@css_styled` false), a `:focused` control whose
      # focused style carries no visible distinction of its own (no fg/bg/reverse
      # — e.g. lazily falling back to `normal`) is shown via reverse-video, so the
      # focused control reads with no theme. Widgets that don't opt in (the
      # default — containers, lists, text editors) are returned untouched, so
      # focus never wholesale-inverts a large viewport. Under any theme the widget
      # is `css_styled` and the cascade-computed style is returned as-is; a `#dup`
      # is taken before toggling so a shared style is never mutated in place.
      private def focus_highlight_fallback(st : ::Crysterm::Style) : ::Crysterm::Style
        return st unless floor_focus_reverse?
        return st if @css_styled || st.specified?(:fg) || st.specified?(:bg) || st.reverse?
        st = st.dup
        st.reverse = true
        st
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
      # Current style being (or to be) applied during rendering.
      # This variable is managed by Crysterm and points to currently valid/active style.
      # Therefore it is kept in sync (modified together) with `Widget#state`.
      # It is a reference to current style, and editing the style through this reference has not been prevented.
      # Thus, editing `style` will edit whatever object's `style` is pointing to.
      # But note: if widget is e.g. in state `focused` but no special style for focus was defined,
      # widget will render use style `normal`. Editing `style` while widget is in that state
      # will then actually edit the state for `normal`, not `focused`.
      # property style : Style # = Style.new # Placeholder

    end
  end
end
