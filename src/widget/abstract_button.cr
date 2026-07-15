require "./input"

module Crysterm
  class Widget
    # Abstract base for the button family, modeled after Qt's `QAbstractButton`.
    #
    # `Button` (push/checkable), `ToolButton`, `CheckBox` and `RadioButton` all
    # derive this directly as siblings, matching Qt's
    # `QPushButton`/`QToolButton`/`QCheckBox`/`QRadioButton` under
    # `QAbstractButton` (rather than chaining `QToolButton` off `QPushButton` or
    # `QRadioButton` off `QCheckBox`).
    #
    # Holds the shared `QAbstractButton`-level state — `#text`, `#checkable?`,
    # `#checked?`, `#group` — and the canonical activate/toggle behavior
    # (`#click`/`#toggle`/`#check`/`#uncheck` plus activate-key/click handlers).
    # Push-style buttons (`Button`, `ToolButton`) inherit this wholesale; marker
    # controls (`CheckBox`, `RadioButton`) override rendering/toggle and wire
    # their own input via `Mixin::CheckMarker`.
    abstract class AbstractButton < Input
      # The button's text label (Qt's `QAbstractButton#text`) — the one label
      # API for the family. The push buttons store it as their `#content` (so
      # `text:` and `content:` can never disagree); `ToolButton` adds/strips its
      # `▾` indicator around it, and the marker controls (`Mixin::CheckMarker`)
      # back it with their own ivar and draw it after the `[x]`/`(*)` glyph.
      def text : String
        content
      end

      # :ditto:
      def text=(value : String) : String
        set_content value
        request_render
        value
      end

      # Whether the button keeps a sticky checked state rather than acting as a
      # momentary push button (Qt's `QAbstractButton#checkable`). The marker
      # controls set this true (they are inherently checkable).
      getter? checkable : Bool = false

      # Sets checkability (Qt's `setCheckable`), re-cascading (`:checked` only
      # ever matches a checkable button) and repainting on a real change. A bare
      # `property?` setter only assigned the ivar, so neither happened.
      def checkable=(value : Bool) : Bool
        return value if value == @checkable
        # Uncheck *before* dropping checkability: `#uncheck` is gated on
        # `#checkable?`, and a button left `checked?` while no longer checkable
        # would keep matching `:checked` with no way to clear it.
        uncheck unless value
        @checkable = value
        invalidate_css
        request_render
        value
      end

      # Current toggle state; only meaningful when `#checkable?`
      # (Qt's `QAbstractButton#checked`).
      getter? checked : Bool = false

      # Sets the checked state (Qt's `setChecked`), routing through
      # `#check`/`#uncheck` so the re-cascade, the `Event::Check`/`UnCheck` emit
      # and the repaint all happen. A bare `property?` setter only assigned the
      # ivar, leaving `:checked` selectors and the painted marker stale. No-op
      # unless `#checkable?`, hence the honest `#checked?` return.
      def checked=(value : Bool) : Bool
        value ? check : uncheck
        @checked
      end

      # The `ButtonGroup` this button belongs to, or `nil` (Qt's
      # `QAbstractButton#group`). A `RadioButton` grouped by containment under a
      # `Widget::RadioSet` has no `ButtonGroup` and reports `nil` — see
      # `RadioSet#checked_button` for that model's counterpart.
      getter group : ::Crysterm::ButtonGroup?

      # :nodoc:
      # Assigned by `ButtonGroup#add` / cleared by `#remove`; not a user knob
      # (membership is owned by the group, and assigning here would leave the
      # group's own list out of sync).
      setter group

      def initialize(text : String? = nil, checkable : Bool = false, checked : Bool = false, **input)
        super **input
        @checkable = checkable
        @checked = checked

        # `text:` is the family-level spelling of `content:`; assigning it after
        # `super` routes through the subclass's `#text=`, so each renders it the
        # way it renders any other label.
        text.try { |t| self.text = t }

        # Activate-key wiring is shared by the whole family (push buttons and the
        # marker controls both activate on Space/Enter), so it lives here rather
        # than in each subclass — a subclass can no longer be silently dead to
        # the keyboard by forgetting it. The `Click` wiring is push-only and
        # stays in `Button`/`ToolButton` (the marker controls hit-test the marker
        # glyph via `Mouse` instead — see `Mixin::CheckMarker`).
        handle Crysterm::Event::KeyPress
      end

      # Activates the button (Qt's `QAbstractButton#click`): focuses it (unless
      # `#focus_on_click?` is off), emits `Event::Press`, and toggles the checked
      # state when `#checkable?`.
      #
      # A keyboard activation already has focus, so gating on `#focus_on_click?`
      # only suppresses mouse-click focus theft — letting a dialog button opt out
      # (`focus_on_click: false`) so a click doesn't pull focus off a live read
      # (e.g. a `Prompt`'s `LineEdit`), which would end the read as a cancel.
      def click
        focus if focus_on_click?
        emit Crysterm::Event::Press
        toggle if checkable?
      end

      # Flips the checked state (only when `#checkable?`) and emits the matching
      # `Event::Check`/`Event::UnCheck`.
      def toggle
        return unless checkable?
        @checked = !@checked
        invalidate_css # `checked` attribute selector may now match/unmatch
        if @checked
          emit Crysterm::Event::Check, @checked
        else
          emit Crysterm::Event::UnCheck, @checked
        end
        request_render
      end

      # Whether a third, partially-checked (indeterminate) state is currently
      # set. Always false for a plain button; `CheckBox` overrides it (via its
      # `#tristate?` support) so `#check`/`#uncheck` here treat "partial" as a
      # state that a transition must settle out of.
      def partial? : Bool
        false
      end

      # Clears any partially-checked state as part of a `#check`/`#uncheck`
      # transition. No-op for a plain button; `CheckBox` overrides it to reset
      # its `@partial` flag, letting the transition body below live once.
      private def clear_partial : Nil
      end

      # Settles `#checked?` to *to*, clearing any partial state and re-cascading.
      # The identical body of `#check`/`#uncheck`, which differ only in the
      # settle-guard and the emitted event around this.
      private def set_checked(to : Bool) : Nil
        @checked = to
        clear_partial
        invalidate_css
      end

      # Sets the checked state (only when `#checkable?`), emitting `Event::Check`
      # if it changed. Lets a checkable button be driven through the same
      # interface as `CheckBox` (e.g. by `ButtonGroup`).
      def check
        return unless checkable?
        return if checked? && !partial? # already settled on checked
        set_checked true
        emit Crysterm::Event::Check, @checked
        request_render
      end

      # Clears the checked state (only when `#checkable?`), emitting
      # `Event::UnCheck` if it changed. Counterpart to `#check`.
      def uncheck
        return unless checkable?
        return if !checked? && !partial? # already settled on unchecked
        set_checked false
        emit Crysterm::Event::UnCheck, @checked
        request_render
      end

      # Button-family controls indicate focus via reverse-video at the unstyled
      # floor (see `Mixin::Style#floor_focus_reverse?`) — inverting a small,
      # mostly single-line control is the clearest no-color focus cue, unlike a
      # large container/editor, which this hook leaves alone.
      def floor_focus_reverse? : Bool
        true
      end

      # The keyboard activation gesture, invoked by `#on_keypress` on Space/Enter.
      # A push button `#click`s; the marker controls (`CheckBox`/`RadioButton`)
      # override this via `Mixin::CheckMarker` to `#toggle` instead, so one
      # `#on_keypress` serves the whole family.
      protected def activate
        click
      end

      def on_keypress(e)
        if e.activates?
          e.accept
          activate
        end
      end

      def on_click(e)
        click
      end
    end
  end
end
