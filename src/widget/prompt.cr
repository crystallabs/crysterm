require "./node"
require "./element"
require "./box"

module Crysterm
  module Widget
    class Prompt < Box
      property text : String = ""

      @hidden = true

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
        align: AlignmentFlag::Center,
        # bg: "black",
        # hover_bg: "blue",
        auto_focus: false,
              # mouse: true
)

      @cancel = Button.new(
        left: 10,
        top: 5,
        width: 8,
        height: 1,
        resizable: true,
        content: "Cancel",
        align: AlignmentFlag::Center,
        # bg: "black",
        # hover_bg: "blue",
        auto_focus: false,
              # mouse: true
)

      def initialize(**box)
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

        @screen.save_focus
        #focus

        #ev_keys = @screen.on(KeyPressEvent) do |e|
        #  next unless (e.key == Tput::Key::Enter || e.key == Tput::Key::Escape)
        #  done.call nil, e.key == Tput::Key::Enter
        #end

        ev_ok = @ok.on(PressEvent) do
          @textinput.submit
        end

        ev_cancel = @cancel.on(PressEvent) do
          @textinput.cancel
        end

        @textinput.read_input do |err, data|
          hide
          @screen.restore_focus
          @ok.off PressEvent, ev_ok
          @cancel.off PressEvent, ev_cancel

          callback.try do |c|
            c.call err, data
          end
        end

        @screen.render
      end

    end
  end
end
