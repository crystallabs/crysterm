require "./box"

module Crysterm
  class Widget
    # Form container.
    #
    # A `Form` groups a number of input widgets (text boxes, checkboxes, radio
    # buttons, lists, buttons, ...) placed anywhere in its subtree and provides:
    #
    # * **Keyboard navigation** between the focusable children. `Tab`/
    #   `Shift+Tab` are handled by the window's `tab_navigation` (one focus
    #   ring for the whole window, as in Qt): they enter the form at its first
    #   entry, step through the entries, and continue past the last one to the
    #   next widget outside the form — symmetrically in both directions. The
    #   form itself is never a Tab stop (like a `NoFocus` Qt container). With
    #   `keys: true, vi_keys: true`, `j`/`k` additionally cycle within the
    #   form, wrapping at its edges.
    # * **Submission** — `#submit` walks the subtree, collects each input's
    #   natively-typed value into a `FormData` and emits `Event::FormSubmitted`.
    # * **Reset** — `#reset` returns every input child to its initial state and
    #   emits `Event::Reset`.
    #
    # Keyboard navigation uses `#focus_next`/`#focus_previous`/`#focus_first`/
    # `#focus_last`.
    #
    # ```
    # form = Widget::Form.new keys: true
    # name = Widget::LineEdit.new parent: form, name: "name", top: 0, height: 1
    # ok = Widget::Button.new parent: form, name: "ok", top: 2, content: "OK"
    #
    # form.on(Crysterm::Event::FormSubmitted) do |e|
    #   # e.data["name"] holds the entered text (a String; a CheckBox
    #   # contributes a Bool, a SpinBox an Int32, a DateEdit a Time, ...)
    # end
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Form screenshot](../../tests/widget/form/form.5s.apng)
    # <!-- /widget-examples:capture -->
    class Form < Box
      # Nested-name aliases for the submission types, which live at the
      # `Crysterm` level (in `event.cr`, beside the `Event::FormSubmitted`
      # event that carries them) so the core event catalog does not reference
      # a concrete widget type. `Widget::Form::FormData` remains the
      # conventional spelling for form users.
      alias FormData = ::Crysterm::FormData

      # :ditto:
      alias FieldValue = ::Crysterm::FormData::FieldValue

      # When enabled, pressing `Enter` in a `LineEdit` child moves focus to the
      # next focusable child (instead of only submitting that field).
      property? auto_next : Bool = false

      # The currently selected (focused) child, as tracked by the navigation
      # methods. May differ from `Window#focused` if focus was changed directly.
      # Assignment is internal; use `#reset_selected` to clear it.
      getter current_field : Widget?
      protected setter current_field

      # Result of the most recent `#submit`. `nil` until the form has been
      # submitted at least once.
      getter submission : FormData?

      # Tracks `LineEdit` children already wired for `auto_next`, so the Submit
      # handler is installed at most once per field.
      @auto_next_wired = Set(UInt64).new

      def initialize(auto_next : Bool = false, **box)
        super **box

        # A form doesn't consume keys itself; it only reacts to keys bubbling
        # up from focused descendants.
        @ignore_keys = true

        @auto_next = auto_next

        if @keys
          # Become keyable so bubbled key events are delivered here (the
          # `accepts_tab_focus?` override below keeps the container itself out
          # of the Tab ring regardless).
          self.keyable = true
          on Crysterm::Event::KeyPress, ->handle_key_press(Crysterm::Event::KeyPress)
        end

        # Wire `auto_next` handlers eagerly as fields are adopted, not lazily on
        # the first `#focusable` call: else submitting a field reached by a
        # direct click never advances, its `Submitted` handler never installed.
        if @auto_next
          on(Crysterm::Event::ChildAdded) { focusable }
        end
      end

      # A form is a container, not a field: like a `NoFocus` Qt container,
      # Tab/Shift+Tab never land on the form itself — they go straight to its
      # entries (each registered in the window's focus ring on its own). The
      # form stays `keyable?` so entry keys still bubble to `#handle_key_press`.
      # An explicit `#focus_policy=` assignment still wins, unlike the base
      # default where an unset policy accepts Tab.
      def accepts_tab_focus? : Bool
        @focus_policy.try(&.accepts_tab?) || false
      end

      # Returns the focusable (keyable) descendants of this form, in tree order.
      # Computed fresh on each call so the list never goes stale as children are
      # added or removed.
      def focusable : Array(Widget)
        list = [] of Widget
        collect_focusable self, list
        list
      end

      private def collect_focusable(el : Widget, list : Array(Widget))
        el.children.each do |child|
          if child.keyable? && child != self
            list << child
            wire_auto_next child
          end
          collect_focusable child, list
        end
      end

      # Installs (once) a Submit handler on a `LineEdit` child so that, when
      # `auto_next` is enabled, submitting the field advances focus.
      private def wire_auto_next(el : Widget)
        return unless @auto_next
        return unless el.is_a? LineEdit
        return unless @auto_next_wired.add? el.object_id
        el.on(Crysterm::Event::Submitted) do
          # Anchor the advance on the field that submitted, so focus moves to
          # *its* successor even when it was focused directly (a click) and
          # `@current_field` still points at the last Tab-navigated field (or nil).
          @current_field = el
          focus_next
          update!
        end
      end

      # Whether any focusable child is currently visible.
      def any_visible_focusable?
        focusable.any? &.style.visible?
      end

      # Returns the next focusable child after the currently selected one,
      # wrapping around, skipping invisible children. Returns `nil` if there are
      # no visible focusable children.
      def next_focusable : Widget?
        offset_focusable 1
      end

      # Returns the previous focusable child before the currently selected one,
      # wrapping around, skipping invisible children. Returns `nil` if there are
      # no visible focusable children.
      def previous_focusable : Widget?
        offset_focusable -1
      end

      private def offset_focusable(direction : Int32, anchored : Bool = true) : Widget?
        list = focusable
        return if list.empty?
        # `!disabled?`: focusing a disabled widget would set `state = :focused`,
        # silently wiping its Disabled state (`WidgetState` is single-valued)
        # and re-enabling it.
        return unless list.any? { |w| w.style.visible? && !w.disabled? }

        # Start from the anchor child if any, otherwise from a direction-aware
        # sentinel: just before the first child for a forward step (so `+1`
        # lands on the first), and on the first child for a backward step (so
        # `-1` wraps to the last). The sentinel must depend on direction: a
        # fixed `-1` would make `-1` compute `(-1 - 1) % size == size - 2`,
        # landing on the second-to-last field.
        size = list.size
        sentinel = direction > 0 ? -1 : 0
        i = sentinel
        if anchored
          # Anchor on the child that *actually* holds focus: with Tab traversal
          # window-driven, a field is routinely focused (window Tab, a click)
          # without the form's own navigation ever running, so `@current_field`
          # alone would restart from the form's edge instead of advancing. It
          # remains the fallback for when focus sits outside the form.
          anchor = @current_field
          if (foc = window?.try(&.focused)) && list.includes?(foc)
            anchor = foc
          end
          i = (list.index(anchor) || sentinel) if anchor
        end
        size.times do
          i = (i + direction) % size
          candidate = list[i]
          if candidate.style.visible? && !candidate.disabled?
            @current_field = candidate
            return candidate
          end
        end

        nil
      end

      # Moves focus to the next focusable child.
      def focus_next
        next_focusable.try &.focus
      end

      # Moves focus to the previous focusable child.
      def focus_previous
        previous_focusable.try &.focus
      end

      # Forgets the currently selected child, so the next `#focus_next` starts
      # from the first child (and `#focus_previous` from the last).
      def reset_selected
        @current_field = nil
      end

      # Focuses the first focusable child. `anchored: false`, not just
      # `reset_selected`: a form field may *hold focus* right now, and the
      # focus anchor would turn "first" into "next after the focused one".
      def focus_first
        reset_selected
        offset_focusable(1, anchored: false).try &.focus
      end

      # Focuses the last focusable child.
      def focus_last
        reset_selected
        offset_focusable(-1, anchored: false).try &.focus
      end

      # Collects the value of every input child into a `FormData`, stores it
      # in `#submission`, emits `Event::FormSubmitted`, and returns it.
      #
      # A child contributes a value only if it is a recognized input type. The
      # field name is the child's `#name`, falling back to its widget type.
      # Inputs sharing a name each contribute their own field (see
      # `FormData#values_for`).
      def submit : FormData
        data = FormData.new
        collect_values self, data
        emit Crysterm::Event::FormSubmitted, data
        @submission = data
      end

      private def collect_values(el : Widget, data : FormData)
        # `.nil?`, not truthiness: an unchecked button's `false` is a value.
        unless (value = field_value(el)).nil?
          name = el.name
          name = el.class.name.split("::").last if name.nil? || name.empty?
          data.add el, name, value
        end
        el.children.each { |child| collect_values child, data }
      end

      # The submitted value of a single widget, or `nil` if it is not an input.
      private def field_value(el : Widget) : FieldValue?
        case el
        # Match `Mixin::TextEditing`, not `PlainTextEdit`: `LineEdit` is a
        # sibling (`< Input`) that only shares the buffer via this mixin.
        when Mixin::TextEditing then el.value
          # `RadioButton`/`CheckBox` are siblings (both `< AbstractButton`), so
          # each needs its own arm.
        when RadioButton then el.checked?
        when CheckBox    then el.checked?
          # Match the mixin, not `List`: `ListTable`/`Tree` are *siblings* of
          # `List`. A `FileManager` is a picker, not a form field, so it is
          # excluded before the mixin arm.
        when FileManager     then nil
        when Mixin::ItemView then el.current_text
          # `SpinBox`/`DoubleSpinBox` are siblings (both `< AbstractSpinBox`);
          # each contributes its native numeric value.
        when DoubleSpinBox then el.value
        when SpinBox       then el.value
        when ComboBox      then el.current_text
          # `DateEdit`/`TimeEdit` are subclasses of `DateTimeEdit`, so they must
          # be matched *before* it. All three contribute a `Time`.
        when DateEdit     then el.date
        when TimeEdit     then el.time
        when DateTimeEdit then el.date_time
        end
      end

      # Emits `Event::Cancelled` to signal the form was dismissed without
      # submitting.
      def cancel
        emit Crysterm::Event::Cancelled
      end

      # Resets every input child to its initial state and emits `Event::Reset`.
      def reset
        reset_children self
        reset_selected
        emit Crysterm::Event::Reset
      end

      private def reset_children(el : Widget)
        case el
        when FileManager then el.refresh
          # Every item view (`List`/`ListTable`/`Tree`), which are siblings.
          # `FileManager` is handled above.
        when Mixin::ItemView then el.current_index = 0
          # Via `Mixin::TextEditing` so `LineEdit` is reset too.
        when Mixin::TextEditing then el.clear
          # `RadioButton` is a sibling of `CheckBox`, so it needs its own arm.
        when RadioButton then el.uncheck
        when CheckBox    then el.uncheck
        when ProgressBar then el.reset
          # Spin boxes reset to their minimum.
        when SpinBox       then el.value = el.minimum
        when DoubleSpinBox then el.value = el.minimum
        when ComboBox      then el.reset
          # Date/time editors have no stored initial value; reset to "now",
          # matching a freshly-constructed editor's default. `DateEdit`/`TimeEdit`
          # are subclasses of `DateTimeEdit`, so match them first.
        when DateEdit     then el.date = Mixin::SectionedField.default_today
        when TimeEdit     then el.time = Mixin::SectionedField.default_today
        when DateTimeEdit then el.date_time = Mixin::SectionedField.default_today
        end
        el.children.each { |child| reset_children child }
      end

      # Tab/Shift+Tab are deliberately NOT handled here: the window's
      # `tab_navigation` owns them (Qt's model — one focus chain per window,
      # walked the same way in both directions), so they traverse into, through
      # and out of the form without trapping focus inside it. Only the vi keys
      # remain form-level, since no window fallback exists for them; they keep
      # the historical wrap-around within the form.
      def handle_key_press(e : Crysterm::Event::KeyPress)
        return if @children.empty?
        return unless @vi_keys

        case e.char
        when 'j'
          e.accept
          focus_next
          update!
        when 'k'
          e.accept
          focus_previous
          update!
        end
      end
    end
  end
end
