require "./box"

module Crysterm
  class Widget
    # Form container.
    #
    # A `Form` groups a number of input widgets (text boxes, checkboxes, radio
    # buttons, lists, buttons, ...) placed anywhere in its subtree and provides:
    #
    # * **Keyboard navigation** between the focusable children. When created
    #   with `keys: true`, `Tab`/`Shift+Tab` move focus to the next/previous
    #   focusable child (and, with `vi: true`, `j`/`k` do the same).
    # * **Submission** — `#submit` walks the subtree, collects each input's
    #   value into a `name => value` `Hash` and emits `Event::SubmitData`.
    # * **Reset** — `#reset` returns every input child to its initial state and
    #   emits `Event::Reset`.
    #
    # Qt-like aliases are provided alongside the Blessed-style names:
    # `#focus_next`/`#next_field`, `#focus_previous`/`#previous_field`,
    # `#focus_first`, `#focus_last`.
    #
    # ```
    # form = Widget::Form.new keys: true
    # name = Widget::LineEdit.new parent: form, name: "name", top: 0, height: 1
    # ok = Widget::Button.new parent: form, name: "ok", top: 2, content: "OK"
    #
    # form.on(Crysterm::Event::SubmitData) do |e|
    #   # e.data["name"] holds the entered text
    # end
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Form screenshot](../../tests/widget/form/form.5s.apng)
    # <!-- /widget-examples:capture -->
    class Form < Box
      # When enabled, pressing `Enter` in a `LineEdit` child moves focus to the
      # next focusable child (instead of only submitting that field).
      property? auto_next : Bool = false

      # The currently selected (focused) child, as tracked by the navigation
      # methods. May differ from `Window#focused` if focus was changed directly.
      property selected : Widget?

      # Result of the most recent `#submit`, i.e. the collected `name => value`
      # pairs. `nil` until the form has been submitted at least once.
      getter submission : Hash(String, String)?

      # Tracks `LineEdit` children already wired for `auto_next`, so the Submit
      # handler is installed at most once per field.
      @auto_next_wired = Set(UInt64).new

      def initialize(auto_next = nil, **box)
        super **box

        # A form does not consume keys itself; it only reacts to keys that
        # bubble up from its focused descendants (see `Window#_listen_keys`).
        @ignore_keys = true

        auto_next.try { |v| @auto_next = v }

        if @keys
          # Become keyable so bubbled key events are delivered here.
          self.keyable = true
          on Crysterm::Event::KeyPress, ->on_keypress(Crysterm::Event::KeyPress)
        end
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
        el.on(Crysterm::Event::Submit) do
          focus_next
          request_render
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

      private def offset_focusable(direction : Int32) : Widget?
        list = focusable
        return if list.empty?
        return unless list.any? &.style.visible?

        # Start from the selected child if it is still part of the form,
        # otherwise from just before the start (so +1 lands on the first child).
        i = (sel = @selected) ? (list.index(sel) || -1) : -1

        size = list.size
        # Step at least once, then keep stepping over invisible children.
        size.times do
          i = (i + direction) % size
          candidate = list[i]
          if candidate.style.visible?
            @selected = candidate
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

      # Qt-like alias for `#focus_next`.
      def next_field
        focus_next
      end

      # Qt-like alias for `#focus_previous`.
      def previous_field
        focus_previous
      end

      # Forgets the currently selected child, so the next `#focus_next` starts
      # from the first child (and `#focus_previous` from the last).
      def reset_selected
        @selected = nil
      end

      # Focuses the first focusable child.
      def focus_first
        reset_selected
        focus_next
      end

      # Focuses the last focusable child.
      def focus_last
        reset_selected
        focus_previous
      end

      # Collects the value of every input child into a `name => value` `Hash`,
      # stores it in `#submission`, emits `Event::SubmitData`, and returns it.
      #
      # A child contributes a value only if it is a recognized input type (text
      # area/box, checkbox, radio button, list and its subclasses). The key is
      # the child's `#name`, falling back to its widget type. If several inputs
      # share a name, their values are joined with newlines (mirroring how
      # Blessed groups same-named fields).
      def submit
        data = {} of String => String
        collect_values self, data
        emit Crysterm::Event::SubmitData, data
        @submission = data
      end

      private def collect_values(el : Widget, data : Hash(String, String))
        if value = field_value el
          name = el.name
          name = el.class.name.split("::").last if name.nil? || name.empty?
          if existing = data[name]?
            data[name] = existing + "\n" + value
          else
            data[name] = value
          end
        end
        el.children.each { |child| collect_values child, data }
      end

      # The submitted value of a single widget, or `nil` if it is not an input.
      private def field_value(el : Widget) : String?
        case el
        # Match the shared `Mixin::TextEditing` rather than `PlainTextEdit`
        # alone: `LineEdit` is a *sibling* (`< Input`), not a subclass, and only
        # shares the text buffer through this mixin. Keying off `PlainTextEdit`
        # silently dropped every `LineEdit` field's value on submit (the form's
        # primary use case — see the class docs' example).
        when Mixin::TextEditing then el.value
          # `RadioButton`/`CheckBox` are siblings (both `< AbstractButton`), so the
          # radio arm must be listed explicitly — `when CheckBox` does not match it.
        when RadioButton then el.checked?.to_s
        when CheckBox    then el.checked?.to_s
        when List        then el.value
        else                  nil
        end
      end

      # Emits `Event::Cancel` to signal the form was dismissed without
      # submitting.
      def cancel
        emit Crysterm::Event::Cancel, ""
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
        when List        then el.selekt 0
          # As in `#field_value`: clear every text field via the shared
          # `Mixin::TextEditing`, so a `LineEdit` (an `Input`, not a
          # `PlainTextEdit`) is reset too.
        when Mixin::TextEditing then el.clear_value
          # `RadioButton` is a sibling of `CheckBox`, so it needs its own arm.
        when RadioButton then el.uncheck
        when CheckBox    then el.uncheck
        when ProgressBar then el.reset
        end
        el.children.each { |child| reset_children child }
      end

      def on_keypress(e : Crysterm::Event::KeyPress)
        return if @children.empty?

        key = e.key
        ch = e.char

        if key == Tput::Key::Tab || (@vi && ch == 'j')
          e.accept
          focus_next
          request_render
          return
        end

        if key == Tput::Key::ShiftTab || (@vi && ch == 'k')
          e.accept
          focus_previous
          request_render
          return
        end
      end
    end
  end
end
