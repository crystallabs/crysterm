require "./box"

module Crysterm
  class Widget
    class Prompt < Box
      property text : String = ""

      # TODO Positioning is bad for buttons.
      # Use a layout for buttons.
      # Also, make unlimited number of buttons/choices possible.
      # XXX Same fixes here and in Question element.
      # Actually OK/Cancel buttons need to be imported from Question.

      @textinput = TextBox.new(
        top: 3,
        height: 1,
        left: 2,
        right: 2,
      )

      @ok = Button.new(
        top: 5,
        height: 1,
        width: 6,
        left: 2,
        resizable: true,
        content: "Okay",
        align: Tput::AlignFlag::Center,
        # bg: "black",
        # hover_bg: "blue",
        focus_on_click: false,
      # mouse: true
)

      @cancel = Button.new(
        left: 10,
        top: 5,
        width: 8,
        height: 1,
        resizable: true,
        content: "Cancel",
        align: Tput::AlignFlag::Center,
        # bg: "black",
        # hover_bg: "blue",
        focus_on_click: false,
      # mouse: true
)

      def initialize(**box)
        # style.visible = false # XXX Enable correctly

        box["content"]?.try do |c|
          @text = c
        end

        super **box

        append @textinput
        append @ok
        append @cancel
      end

      def read_input(text = nil, value = "", &callback : Proc(String, String, Nil))
        set_content text || @text
        show

        @textinput.value = value

        screen.save_focus
        # focus

        # ev_keys = screen.on(Event::KeyPress) do |e|
        #  next unless (e.key == Tput::Key::Enter || e.key == Tput::Key::Escape)
        #  done.call nil, e.key == Tput::Key::Enter
        # end

        ev_ok = @ok.on ::Crysterm::Event::Press, ->on_press_ok(::Crysterm::Event::Press)

        ev_cancel = @cancel.on ::Crysterm::Event::Press, ->on_press_cancel(::Crysterm::Event::Press)

        @textinput.read_input do |err, data|
          hide
          screen.restore_focus
          @ok.off ::Crysterm::Event::Press, ev_ok
          @cancel.off ::Crysterm::Event::Press, ev_cancel

          callback.try do |c|
            c.call err, data
          end
        end

        screen.render
      end

      def on_press_ok(e)
        @textinput.submit
      end

      def on_press_cancel(e)
        @textinput.cancel
      end
    end
  end
end
