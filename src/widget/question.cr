require "./dialog"

module Crysterm
  class Widget
    # Question element
    #
    # <!-- widget-examples:capture v1 -->
    # ![Question screenshot](../../examples/widget/question/question-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Question < Dialog
      include ::Crysterm::Mixin::OkCancelDialog

      property text : String = ""

      # TODO Positioning is bad for buttons.
      # Use a layout for buttons.
      # Also, make unlimited number of buttons/choices possible.

      @ok : Button = ::Crysterm::Mixin::OkCancelDialog.ok_button(top: 4, left: 1, width: 6)
      @cancel : Button = ::Crysterm::Mixin::OkCancelDialog.cancel_button(top: 4, left: 8, width: 8)

      def initialize(ok_text = nil, cancel_text = nil, **box)
        box["content"]?.try do |c|
          @text = c
        end

        super **box

        # Dialogs start hidden, like Blessed's `options.hidden = true`: `ask` /
        # `ask_choices` call `show` to reveal the dialog. Without this it renders
        # on the first frame and stacks with any other dialog on the screen.
        hide

        # Custom button labels (Qt lets you relabel the standard buttons).
        ok_text.try { |t| @ok.set_content t }
        cancel_text.try { |t| @cancel.set_content t }

        # Should not be needed when ivar exists and is already set
        # @visible = box["visible"]? ? true : box["hidden"]? || false

        append @ok
        append @cancel
      end

      def ask(text = nil, &block : String?, Bool -> Nil)
        # D O:
        # Keep above:
        # @parent.try do |p|
        #   detach
        #   p.append self
        # end

        set_content text || @text
        show

        # Declare the listener handles up front so `done` can close over them;
        # they are assigned below, before any of these events can fire.
        ev_keys = nil
        ev_ok = nil
        ev_cancel = nil

        # `done` must be defined *before* the handlers that call it are
        # registered. Previously it was `uninitialized` and only assigned after
        # registration, so a key/press arriving in between would have invoked an
        # uninitialized Proc (crash).
        done = ->(err : String?, data : Bool) do
          teardown_ok_cancel ev_ok, ev_cancel
          ev_keys.try { |h| screen.off Crysterm::Event::KeyPress, h }
          block.call err, data
          request_render
        end

        ev_keys = screen.on(Crysterm::Event::KeyPress) do |e|
          c = e.char
          k = e.key

          if k != Tput::Key::Enter && k != Tput::Key::Escape && c != 'q' && c != 'y' && c != 'n'
            next
          end

          done.call nil, k == Tput::Key::Enter || e.char == 'y'
        end

        ev_ok = @ok.on(Crysterm::Event::Press) do
          done.call nil, true
        end

        ev_cancel = @cancel.on(Crysterm::Event::Press) do
          done.call nil, false
        end

        screen.save_focus
        focus

        request_render
      end

      # Asks the user to pick one of an arbitrary list of *choices*, addressing
      # the long-standing TODO above (Qt-style "multiple standard buttons"). The
      # block receives the chosen 0-based index, or `-1` if dismissed with
      # Escape. Buttons are laid out in a row; Left/Right move focus, Enter/Space
      # or a click activates the focused one.
      def ask_choices(text = nil, choices : Array(String) = ["Okay", "Cancel"], default = 0, &block : Int32 -> Nil)
        set_content text || @text
        show

        # The fixed OK/Cancel pair is not used in this mode.
        @ok.hide
        @cancel.hide

        buttons = [] of Button
        left = 1
        choices.each do |label|
          b = Button.new(
            parent: self,
            left: left,
            top: 4,
            height: 1,
            width: label.size + 2,
            resizable: true,
            content: label,
            align: :center,
            focus_on_click: true,
          )
          left += label.size + 3
          buttons << b
        end

        cur = default.clamp(0, Math.max(0, buttons.size - 1))
        ev_keys = nil

        finish = ->(idx : Int32) do
          ev_keys.try { |h| screen.off Crysterm::Event::KeyPress, h }
          # Move focus onto a surviving widget *before* destroying the choice
          # buttons: removing the currently-focused widget would otherwise trigger
          # a focus rewind mid-teardown (the button is already detached, so its
          # `screen` is gone). `restore_focus` alone isn't enough — there may be
          # no saved focus — so anchor on the (now-shown) OK button.
          @ok.show
          @cancel.show
          @ok.focus
          buttons.each &.destroy
          hide
          screen.restore_focus
          block.call idx
          request_render
        end

        buttons.each_with_index do |b, i|
          b.on(Crysterm::Event::Press) { finish.call i }
        end

        ev_keys = screen.on(Crysterm::Event::KeyPress) do |e|
          case e.key
          when Tput::Key::Left
            next if buttons.empty? # nothing to move between (and `% 0` would crash)
            cur = (cur - 1) % buttons.size
            buttons[cur].focus
            request_render
          when Tput::Key::Right
            next if buttons.empty?
            cur = (cur + 1) % buttons.size
            buttons[cur].focus
            request_render
          when Tput::Key::Escape
            finish.call -1
          end
        end

        screen.save_focus
        buttons[cur]?.try &.focus
        request_render
      end
    end
  end
end
