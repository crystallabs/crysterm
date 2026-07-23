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
    # *Every* button also emits box-level `Event::ButtonClick` carrying the
    # button (Qt's `QDialogButtonBox#clicked`), which `#standard_button` maps
    # back to its `StandardButton`. Each button additionally emits its own
    # `Event::Pressed`, and `#button` gives access to a specific one.
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
        Apply       # Apply             → only its own Event::Pressed
        Reset       # Reset             → only its own Event::Pressed
        Help        # Help              → only its own Event::Pressed
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
        when .ok?      then {"OK", Role::Accept}
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

      # The standard buttons currently in the box (Qt's `standardButtons`).
      getter standard_buttons : StandardButton = StandardButton::None

      def initialize(buttons : StandardButton = StandardButton::None, **box)
        super **box
        build_standard buttons
      end

      # Replaces the set of standard buttons (Qt's `setStandardButtons`). Only
      # the standard buttons are rebuilt; any added via `#add_button` are kept,
      # and — since the rebuilt standard ones are appended after them — end up at
      # the head of the row.
      def standard_buttons=(buttons : StandardButton) : StandardButton
        return buttons if @standard_buttons == buttons
        @standard.each_key do |b|
          @buttons.delete b
          b.destroy
        end
        @standard.clear
        build_standard buttons
        request_render
        buttons
      end

      # Creates, labels and orders the standard buttons in *buttons*, then
      # re-runs the row layout.
      private def build_standard(buttons : StandardButton) : Nil
        @standard_buttons = buttons
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

      # The reverse of `#button`: the `StandardButton` *btn* stands for, or `nil`
      # for one added via `#add_button` (Qt's `standardButton`).
      def standard_button(btn : Button) : StandardButton?
        @standard[btn]?
      end

      # Adds a custom button with *text* and *role*, returning it. Re-runs the
      # row layout. (Qt's `QDialogButtonBox#addButton(text, role)`.)
      def add_button(text : String, role : Role = Role::Accept) : Button
        b = make_button text, role
        relayout
        b
      end

      # Builds one button, appends it, and wires its `Pressed` to the box-level
      # accept/reject signal implied by *role*.
      private def make_button(text : String, role : Role) : Button
        # str_width, not a raw .size: under full_unicode a CJK/emoji label is
        # twice as wide as its codepoint count, and the button must be sized
        # to fit its actual rendered (display-column) width, matching how the
        # box's own content engine wraps the label. (Buttons render with
        # parse_tags: false, so no clean_tags here — brace text is literal.)
        b = ::Crysterm::Mixin::OkCancelDialog.dialog_button(
          text, str_width(text) + 2,
          parent: self, top: 0,
          focus_on_click: true, shrink_to_fit: true,
        )
        b.on(Crysterm::Event::Pressed) do
          # Box-level "some button was clicked" (Qt's `clicked(QAbstractButton*)`),
          # emitted for every role, so a caller can handle the whole row from one
          # handler and resolve `#standard_button` on it.
          emit Crysterm::Event::ButtonClick, b
          case role
          when .accept?                then emit Crysterm::Event::Accepted
          when .reject?, .destructive? then emit Crysterm::Event::Rejected
          else
            # Apply/Reset/Help carry no accept/reject meaning; a caller wanting
            # those listens on `ButtonClick` above.
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
