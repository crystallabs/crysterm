require "./node"
require "./element"
require "./box"

module Crysterm
  # Question element
  class Question < Box
    @ok = Button.new(
      left: 2,
      top: 2,
      width: 6,
      height: 1,
      content: "Okay",
      align: "center",
      # bg: "black",
      # hover_bg: "blue",
      auto_focus: false,
          # mouse: true
)

    @cancel = Button.new(
      left: 10,
      top: 2,
      width: 20,
      height: 1,
      resizable: true,
      content: "Cancel",
      align: "center",
      # bg: "black",
      # hover_bg: "blue",
      auto_focus: false,
          # mouse: true
)

    def initialize(hidden = true, **box)
      super **box, hidden: hidden

      append @ok
      append @cancel
    end

    def ask(text, &block : String?, Bool -> Nil)
      # D O:
      # Keep above:
      # var parent = @parent;
      # @detach();
      # parent.append(this);

      show
      set_content ' ' + text

      done = uninitialized String?, Bool -> Nil

      ev_keys = @screen.on(KeyPressEvent) do |e|
        # if (e.key == 'mouse')
        #  return
        # end
        c = e.char
        k = e.key

        if (k != Tput::Key::Enter &&
           k != Tput::Key::Escape &&
           c != 'q' &&
           c != 'y' &&
           c != 'n')
          next
        end

        done.call nil, k == Tput::Key::Enter || e.char == 'y'
      end

      ev_ok = @ok.on(PressEvent) do
        done.call nil, true
      end

      ev_cancel = @cancel.on(PressEvent) do
        done.call nil, false
      end

      @screen.save_focus
      focus

      done = ->(err : String?, data : Bool) do
        hide
        @screen.restore_focus
        @screen.off KeyPressEvent, ev_keys
        @ok.off PressEvent, ev_ok
        @cancel.off PressEvent, ev_cancel
        block.call err, data
      end

      @screen.render
    end
  end
end
