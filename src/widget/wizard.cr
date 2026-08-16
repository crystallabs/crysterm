require "./dialog"
require "./button"
require "../mixin/paged_container"

module Crysterm
  class Widget
    # Multi-page assistant, modeled after Qt's `QWizard`.
    #
    # Holds an ordered set of `#pages` above a button row with
    # **Back**, **Next**/**Finish** and **Cancel**. Back is disabled on the first
    # page; on the last page Next becomes Finish. Navigation emits `Event::Activated`
    # (the new page's title) on each page change, `Event::Completed` when Finish is
    # pressed on the last page, and `Event::Cancelled` when Cancel is pressed. Finish
    # and Cancel additionally close the wizard through the `Dialog` result
    # protocol (`Event::Accepted`/`Rejected`, then `Event::Finished`).
    #
    # ```
    # wiz = Widget::Wizard.new parent: window, width: 50, height: 16, style: Style.new(border: true)
    # wiz.add_page "Intro", Widget::Box.new(content: "Welcome")
    # wiz.add_page "Details", Widget::Form.new
    # wiz.on(Event::Completed) { finish! }
    # ```
    # Excluded from the DOM-loader registry: self-populating composite
    # (see `Crysterm::DOM::Skip`).
    @[::Crysterm::DOM::Skip]
    # <!-- widget-examples:capture v1 -->
    # ![Wizard screenshot](../../tests/widget/wizard/wizard.5s.apng)
    # <!-- /widget-examples:capture -->
    class Wizard < Dialog
      # `#pages`, `#count`, `#current_index`/`#current_index=`,
      # `#current_widget`, `#widget`/`#index_of` and the show/`next_page`/
      # `#previous_page` core all come from here — a wizard *is* a paged
      # container, so it needs no `StackedWidget` wrapper of its own. Only the
      # genuinely wizard-shaped verbs are defined here:
      # `#back` (previous page, but never wrapping — Back is *disabled* on the
      # first page) and `#advance` (next page, or Finish on the last).
      include Mixin::PagedContainer
      include Mixin::WindowLifecycle

      getter! back_button : Button
      getter! next_button : Button
      getter! cancel_button : Button

      # Per-page titles, parallel to `#pages`.
      getter titles = [] of String

      # Rows reserved for the button row.
      property button_height : Int32 = 1

      def initialize(button_height = 1, **box)
        @button_height = button_height

        super **box

        @back_button = wizard_button "Back", left: 0
        @cancel_button = wizard_button "Cancel", right: 10
        @next_button = wizard_button "Next", right: 0

        back_button.on(::Crysterm::Event::Clicked) { back }
        next_button.on(::Crysterm::Event::Clicked) { advance }
        cancel_button.on(::Crysterm::Event::Clicked) { reject }

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
      # this one hook, not in an `#accept` override, which would break the
      # `Dialog#accept` contract: Enter → `#advance` (which calls `#accept`
      # itself once there's nothing left to advance to). Escape (→ `#reject`) and
      # the gating in `Dialog#dialog_keys_active?` are inherited unchanged.
      protected def dialog_enter_gesture : Nil
        advance
      end

      # Builds one of the wizard's footer buttons: a centered `Button` pinned to
      # the bottom row with the given left/right anchor.
      private def wizard_button(label : String, left = nil, right = nil) : Button
        ::Crysterm::Mixin::OkCancelDialog.dialog_button(
          label, 8,
          parent: self, bottom: 0, left: left, right: right,
        )
      end

      # Appends *page* titled *title* and refreshes the buttons. Title-first
      # argument order, matching every other container add-verb in the toolkit (a
      # deliberate, uniform deviation from Qt's widget-first `addPage`). Returns `self`.
      def add_page(title : String, page : Widget) : self
        @titles << title
        # Fill the wizard above the button row.
        stretch_child page, top: 0, bottom: @button_height
        @pages << page
        append page
        register_page page
        refresh_buttons
        self
      end

      # :ditto: — untitled overload for when a page needs no caption.
      def add_page(page : Widget) : self
        add_page "", page
      end

      # Goes to the previous page (no-op on the first). Distinct from the mixin's
      # `#previous_page`: Back never wraps to the last page — it is simply
      # unavailable on the first.
      def back : Nil
        return if current_index <= 0
        self.current_index = current_index - 1
      end

      # Goes to the next page, or finishes when already on the last page —
      # emitting `Event::Completed` and then accepting the wizard (Qt's Finish
      # button triggers `QDialog#accept`), so it closes with `Code::Accepted`.
      def advance : Nil
        # A page-less wizard sits at the `-1` `current_index` sentinel; treat it
        # as having nothing to advance or complete (pages are added after
        # construction), so it can't "finish" with zero pages.
        return if count == 0
        if current_index >= count - 1
          emit ::Crysterm::Event::Completed
          accept
        else
          self.current_index = current_index + 1
        end
      end

      # Cancels the wizard: emits `Event::Cancelled` on top of the standard
      # rejection (`Event::Rejected` + `Event::Finished`, via `Dialog#reject`).
      def reject : Nil
        emit ::Crysterm::Event::Cancelled
        super
      end

      # Per-page-change work (`Mixin::PagedContainer` hook): refresh the button
      # row and announce the new page's title.
      protected def after_show_index(index : Int) : Nil
        refresh_buttons
        emit ::Crysterm::Event::Activated, @titles[index]? || ""
        update!
      end

      # Reflects the current position in the button row: Back disabled on the
      # first page, Next labeled "Finish" on the last.
      private def refresh_buttons : Nil
        first = current_index <= 0
        # With no pages there is no "last" page to finish on — the `-1 >= -1`
        # sentinel would otherwise render an active "Finish".
        last = count > 0 && current_index >= count - 1

        back_button.state = first ? WidgetState::Disabled : WidgetState::Normal
        next_button.set_content(last ? "Finish" : "Next")
        update!
      end
    end
  end
end
