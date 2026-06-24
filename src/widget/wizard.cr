require "./box"
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
    # wiz = Widget::Wizard.new parent: screen, width: 50, height: 16, style: Style.new(border: true)
    # wiz.add_page Widget::Box.new(content: "Welcome"), title: "Intro"
    # wiz.add_page Widget::Form.new, title: "Details"
    # wiz.on(Event::Complete) { finish! }
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Wizard screenshot](../../examples/widget/wizard/wizard-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Wizard < Box
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

        @back_button = Button.new(
          parent: self, bottom: 0, left: 0, height: 1, width: 8,
          content: "{center}Back{/center}", parse_tags: true,
        )
        @cancel_button = Button.new(
          parent: self, bottom: 0, right: 10, height: 1, width: 8,
          content: "{center}Cancel{/center}", parse_tags: true,
        )
        @next_button = Button.new(
          parent: self, bottom: 0, right: 0, height: 1, width: 8,
          content: "{center}Next{/center}", parse_tags: true,
        )

        back_button.on(::Crysterm::Event::Press) { back }
        next_button.on(::Crysterm::Event::Press) { advance }
        cancel_button.on(::Crysterm::Event::Press) { cancel }

        refresh_buttons
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
        last = current_index >= page_count - 1

        back_button.state = first ? WidgetState::Disabled : WidgetState::Normal
        next_button.set_content(last ? "{center}Finish{/center}" : "{center}Next{/center}")
        request_render
      end
    end
  end
end
