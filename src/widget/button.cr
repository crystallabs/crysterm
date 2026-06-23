require "./input"

module Crysterm
  class Widget
    # Button element, modeled after Qt's `QPushButton`.
    #
    # By default it is a momentary push button: activating it (Space/Enter or a
    # click) emits `Event::Press`. When `#checkable?` it instead behaves as a
    # toggle button — each activation flips `#checked?` and emits `Event::Check`
    # or `Event::UnCheck` (in addition to `Event::Press`), like a checkable
    # `QPushButton` or a `QToolButton`.
    class Button < Input
      include EventHandler

      getter value = false

      # Whether the button toggles a sticky checked state instead of acting as a
      # momentary push button (Qt's `QAbstractButton#checkable`).
      property? checkable : Bool = false

      # Current toggle state; only meaningful when `#checkable?`
      # (Qt's `QAbstractButton#checked`).
      property? checked : Bool = false

      def initialize(checkable : Bool = false, checked : Bool = false, **input)
        super **input

        @checkable = checkable
        @checked = checked

        handle Crysterm::Event::KeyPress
        handle Crysterm::Event::Click
      end

      def press
        focus
        @value = true
        emit Crysterm::Event::Press
        @value = false

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

      # Sets the checked state (only when `#checkable?`), emitting `Event::Check`
      # if it changed. Mirrors `CheckBox#check` so a checkable button can be
      # driven through the same interface (e.g. by `ButtonGroup`).
      def check
        return unless checkable?
        return if checked?
        @checked = true
        invalidate_css
        emit Crysterm::Event::Check, @checked
        request_render
      end

      # Clears the checked state (only when `#checkable?`), emitting
      # `Event::UnCheck` if it changed. Counterpart to `#check`.
      def uncheck
        return unless checkable?
        return unless checked?
        @checked = false
        invalidate_css
        emit Crysterm::Event::UnCheck, @checked
        request_render
      end

      def on_keypress(e)
        if e.activates?
          e.accept
          press
        end
      end

      def on_click(e)
        # e.accept
        press
      end
    end
  end
end
