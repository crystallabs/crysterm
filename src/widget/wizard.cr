require "./dialog"
require "./stacked_widget"
require "./button"

module Crysterm
  class Widget
    # Multi-page assistant, modeled after Qt's `QWizard`.
    #
    # Holds an ordered set of pages (a `StackedWidget`) above a button row with
    # **Back**, **Next**/**Finish** and **Cancel**. Back is disabled on the first
    # page; on the last page Next becomes Finish. Navigation emits `Event::Action`
    # (the new page's title) on each page change, `Event::Complete` when Finish is
    # pressed on the last page, and `Event::Cancel` when Cancel is pressed.
    #
    # ```
    # wiz = Widget::Wizard.new parent: window, width: 50, height: 16, style: Style.new(border: true)
    # wiz.add_page Widget::Box.new(content: "Welcome"), title: "Intro"
    # wiz.add_page Widget::Form.new, title: "Details"
    # wiz.on(Event::Complete) { finish! }
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Wizard screenshot](../../tests/widget/wizard/wizard.5s.apng)
    # <!-- /widget-examples:capture -->
    class Wizard < Dialog
      # The page stack. (Built in `initialize` after `super`, hence `getter!`.)
      getter! stack : StackedWidget

      getter! back_button : Button
      getter! next_button : Button
      getter! cancel_button : Button

      # Per-page titles, parallel to `stack.pages`.
      getter titles = [] of String

      # Rows reserved for the button row.
      property button_height : Int32 = 1

      def initialize(button_height = 1, **box)
        @button_height = button_height

        super **box

        @stack = StackedWidget.new(
          parent: self,
          top: 0, left: 0, right: 0,
          bottom: @button_height,
        )

        @back_button = wizard_button "Back", left: 0
        @cancel_button = wizard_button "Cancel", right: 10
        @next_button = wizard_button "Next", right: 0

        back_button.on(::Crysterm::Event::Press) { back }
        next_button.on(::Crysterm::Event::Press) { advance }
        cancel_button.on(::Crysterm::Event::Press) { cancel }

        # Enter advances/finishes, Escape cancels — the modal-dialog convention
        # `ColorDialog`/`Question` already follow, which `Wizard` had missed
        # entirely (cancel was reachable only via the button). The `Dialog` base
        # owns the window-level accelerator; the wizard keeps it installed while
        # attached and torn down on detach/destroy so it can't fire on a dead
        # widget.
        on(::Crysterm::Event::Attach) { install_dialog_keys }
        on(::Crysterm::Event::Detach) { uninstall_dialog_keys }
        on(::Crysterm::Event::Destroy) { uninstall_dialog_keys }
        install_dialog_keys # in case we are already on a window (parent: window)

        refresh_buttons
      end

      # For the wizard the affirmative gesture is "advance" (Enter → next page /
      # Finish on the last), not a single close — see `#advance`.
      def accept : Nil
        advance
      end

      # The window's own key routing delivers to the focused widget *first* (see
      # `window_interaction.cr`); if that widget already consumed the key — a text
      # editor taking Enter, a focused footer button activating on it —
      # `e.accepted?` is set and the accelerator stands down, so it never hijacks
      # a field's Enter nor double-advances when a button already handled it.
      protected def dialog_keys_active?(e : Crysterm::Event::KeyPress) : Bool
        !e.accepted?
      end

      # Builds one of the wizard's footer buttons: a centered `Button` pinned to
      # the bottom row with the given left/right anchor. Uses `align: :center`
      # like the rest of the dialog-button family (`DialogButtonBox#make_button`,
      # `OkCancelDialog.dialog_button`) rather than the `{center}` tag form it had
      # drifted to (same result, one styling convention across the dialogs).
      private def wizard_button(label : String, left = nil, right = nil) : Button
        Button.new(
          parent: self, bottom: 0, left: left, right: right, height: 1, width: 8,
          content: label, align: :center,
        )
      end

      # Index of the current page.
      def current_index : Int32
        stack.current_index
      end

      # Number of pages.
      def page_count : Int32
        stack.count
      end

      # Appends *page* (optionally titled) and refreshes the buttons.
      def add_page(page : Widget, title : String = "") : self
        @titles << title
        stack.add_page page
        refresh_buttons
        self
      end

      # Goes to the previous page (no-op on the first).
      def back : Nil
        return if current_index <= 0
        stack.previous_page
        after_change
      end

      # Goes to the next page, or finishes when already on the last page.
      def advance : Nil
        # A page-less wizard sits at the `-1` `current_index` sentinel; treat it
        # as having nothing to advance or complete (pages are added after
        # construction), so it can't "finish" with zero pages.
        return if page_count == 0
        if current_index >= page_count - 1
          emit ::Crysterm::Event::Complete
        else
          stack.next_page
          after_change
        end
      end

      # Cancels the wizard.
      def cancel : Nil
        emit ::Crysterm::Event::Cancel, ""
      end

      private def after_change : Nil
        refresh_buttons
        emit ::Crysterm::Event::Action, @titles[current_index]? || ""
        request_render
      end

      # Reflects the current position in the button row: Back disabled on the
      # first page, Next labeled "Finish" on the last.
      private def refresh_buttons : Nil
        first = current_index <= 0
        # With no pages there is no "last" page to finish on — the `-1 >= -1`
        # sentinel would otherwise render an active "Finish".
        last = page_count > 0 && current_index >= page_count - 1

        back_button.state = first ? WidgetState::Disabled : WidgetState::Normal
        next_button.set_content(last ? "Finish" : "Next")
        request_render
      end
    end
  end
end
