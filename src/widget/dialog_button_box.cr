require "./box"
require "./button"

module Crysterm
  class Widget
    # A horizontal row of standard dialog buttons, modeled after Qt's
    # `QDialogButtonBox`.
    #
    # Declare which standard buttons you want and the box creates, labels,
    # orders and wires them for you:
    #
    # ```
    # bb = Widget::DialogButtonBox.new(
    #   parent: dialog,
    #   buttons: Widget::DialogButtonBox::StandardButton::Ok |
    #            Widget::DialogButtonBox::StandardButton::Cancel,
    # )
    # bb.on(Crysterm::Event::Accepted) { dialog.accept }
    # bb.on(Crysterm::Event::Rejected) { dialog.reject }
    # ```
    #
    # Buttons with an accepting role (Ok/Save/Yes/…) emit `Event::Accepted` on
    # the box; rejecting ones (Cancel/No/Close/Discard) emit `Event::Rejected`.
    # Every button additionally emits its own `Event::Press`, and `#button`
    # gives access to a specific one for custom handling.
    #
    # <!-- widget-examples:capture v1 -->
    # ![DialogButtonBox screenshot](../../tests/widget/dialog_button_box/dialog_button_box.5s.apng)
    # <!-- /widget-examples:capture -->
    class DialogButtonBox < Box
      # The set of standard buttons (a flags enum, combine with `|`). The label
      # and `Role` of each are fixed by `descriptor_for`.
      @[Flags]
      enum StandardButton
        Ok
        Save
        Apply
        Retry
        Yes
        No
        Discard
        Cancel
        Close
        Reset
        Help
      end

      # The behavioural role of a button, deciding which box-level signal it
      # emits (Qt's `QDialogButtonBox::ButtonRole`).
      enum Role
        Accept      # Ok/Save/Yes/Retry → Event::Accepted
        Reject      # Cancel/No/Close   → Event::Rejected
        Destructive # Discard           → Event::Rejected
        Apply       # Apply             → only its own Event::Press
        Reset       # Reset             → only its own Event::Press
        Help        # Help              → only its own Event::Press
      end

      # Left-to-right display order of the standard buttons (affirmative first,
      # then negative, with auxiliary buttons last).
      DISPLAY_ORDER = [
        StandardButton::Ok, StandardButton::Save, StandardButton::Apply,
        StandardButton::Retry, StandardButton::Yes, StandardButton::No,
        StandardButton::Discard, StandardButton::Cancel, StandardButton::Close,
        StandardButton::Reset, StandardButton::Help,
      ]

      # The label/role of each standard button.
      def self.descriptor_for(b : StandardButton) : {String, Role}
        case b
        when .ok?      then {"Okay", Role::Accept}
        when .save?    then {"Save", Role::Accept}
        when .yes?     then {"Yes", Role::Accept}
        when .retry?   then {"Retry", Role::Accept}
        when .cancel?  then {"Cancel", Role::Reject}
        when .no?      then {"No", Role::Reject}
        when .close?   then {"Close", Role::Reject}
        when .discard? then {"Discard", Role::Destructive}
        when .apply?   then {"Apply", Role::Apply}
        when .reset?   then {"Reset", Role::Reset}
        when .help?    then {"Help", Role::Help}
        else                {"", Role::Apply}
        end
      end

      # The contained buttons, in display order.
      getter buttons = [] of Button

      # The standard button each contained `Button` stands for (nil for ones
      # added via `#add_button`). Indexed in lockstep with `#buttons`.
      @standard = {} of Button => StandardButton

      def initialize(buttons : StandardButton = StandardButton::None, **box)
        super **box

        DISPLAY_ORDER.each do |sb|
          next unless buttons.includes? sb
          text, role = self.class.descriptor_for sb
          b = make_button text, role
          @standard[b] = sb
        end

        relayout
      end

      # Returns the `Button` created for *which*, or `nil` if it wasn't requested.
      def button(which : StandardButton) : Button?
        @standard.each { |btn, sb| return btn if sb == which }
        nil
      end

      # Adds a custom button with *text* and *role*, returning it. Re-runs the
      # row layout. (Qt's `QDialogButtonBox#addButton(text, role)`.)
      def add_button(text : String, role : Role = Role::Accept) : Button
        b = make_button text, role
        relayout
        b
      end

      # Builds one button, appends it, and wires its `Press` to the box-level
      # accept/reject signal implied by *role*.
      private def make_button(text : String, role : Role) : Button
        b = ::Crysterm::Mixin::OkCancelDialog.dialog_button(
          text, text.size + 2,
          parent: self, top: 0,
          focus_on_click: true, resizable: true,
        )
        b.on(Crysterm::Event::Press) do
          case role
          when .accept?                then emit Crysterm::Event::Accepted
          when .reject?, .destructive? then emit Crysterm::Event::Rejected
          else
            # Apply/Reset/Help carry no box-level meaning; the caller listens on
            # the button itself (via `#button`).
          end
        end
        @buttons << b
        b
      end

      # Re-spaces the buttons in a single left-to-right row and sizes the box to
      # fit them (its content is the child buttons, not text, so shrink-to-
      # content doesn't apply).
      private def relayout : Nil
        left = 0
        @buttons.each do |b|
          b.left = left
          b.top = 0
          w = b.width
          left += (w.is_a?(Int) ? w : 0) + 1
        end
        unless @buttons.empty?
          self.width = left - 1 # drop the trailing gap
          self.height = 1
        end
      end
    end
  end
end
