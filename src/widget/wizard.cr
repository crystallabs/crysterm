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
    # pressed on the last page, and `Event::Cancel` when Cancel is pressed. Finish
    # and Cancel additionally close the wizard through the `Dialog` result
    # protocol (`Event::Accepted`/`Rejected`, then `Event::Finished`).
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
      include Mixin::WindowLifecycle

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
        cancel_button.on(::Crysterm::Event::Press) { reject }

        # Enter advances/finishes, Escape cancels. The accelerator stays
        # installed while attached and is torn down on detach/destroy so it
        # can't fire on a dead widget.
        wire_window_lifecycle destroy: true

        refresh_buttons
      end

      # Enter/Escape accelerator lives with the window: (re)install on attach,
      # tear down on detach/destroy.
      private def on_attach_window : Nil
        install_dialog_keys
      end

      # :ditto:
      private def on_detach_window : Nil
        uninstall_dialog_keys
      end

      # Enter **advances** rather than accepting outright — a wizard's Enter means
      # "next page", and only on the last page does it finish. The remap lives in
      # the accelerator, not in an `#accept` override, which would break the
      # `Dialog#accept` contract: Enter → `#advance` (which calls `#accept`
      # itself once there's nothing left to advance to), Escape → `#reject`.
      protected def dialog_key(e : Crysterm::Event::KeyPress) : Nil
        return if e.accepted?
        return unless dialog_keys_active? e
        case e.key
        when Tput::Key::Enter  then advance; e.accept
        when Tput::Key::Escape then reject; e.accept
        end
        request_render if e.accepted?
      end

      # The window routes keys to the focused widget first, so `e.accepted?`
      # means a field's Enter or a footer button already handled it and the
      # accelerator must stand down. A hidden wizard (e.g. on a non-current
      # stack page) keeps the accelerator installed while attached, so it must
      # also stand down while invisible — otherwise it steals every unconsumed
      # Enter/Escape, advancing pages and emitting Complete/Cancel invisibly.
      protected def dialog_keys_active?(e : Crysterm::Event::KeyPress) : Bool
        !e.accepted? && visible_in_tree?
      end

      # Builds one of the wizard's footer buttons: a centered `Button` pinned to
      # the bottom row with the given left/right anchor.
      private def wizard_button(label : String, left = nil, right = nil) : Button
        ::Crysterm::Mixin::OkCancelDialog.dialog_button(
          label, 8,
          parent: self, bottom: 0, left: left, right: right,
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

      # Goes to the next page, or finishes when already on the last page —
      # emitting `Event::Complete` and then accepting the wizard (Qt's Finish
      # button triggers `QDialog#accept`), so it closes with `Code::Accepted`.
      def advance : Nil
        # A page-less wizard sits at the `-1` `current_index` sentinel; treat it
        # as having nothing to advance or complete (pages are added after
        # construction), so it can't "finish" with zero pages.
        return if page_count == 0
        if current_index >= page_count - 1
          emit ::Crysterm::Event::Complete
          accept
        else
          stack.next_page
          after_change
        end
      end

      # Cancels the wizard: emits `Event::Cancel` on top of the standard
      # rejection (`Event::Rejected` + `Event::Finished`, via `Dialog#reject`).
      def reject : Nil
        emit ::Crysterm::Event::Cancel, ""
        super
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
