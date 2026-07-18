require "../../src/crysterm"

module Crysterm
  include Widgets # avoids writing e.g. `Widget::Box`

  s = Window.new propagate_keys: false, always_propagated_keys: [Tput::Key::CtrlQ]

  b = Box.new(
    top: "center",
    left: "center",
    width: "70%",
    shrink_to_fit: true,
    style: Style.new(border: true),
    content: "Press Ctrl+q to quit. It should work even though display's keys are locked."
  )

  s.append b

  s.on(Event::KeyPress) do |e|
    if e.key == Tput::Key::CtrlQ
      s.destroy

      case ARGV[0]?
      when "resume"
        # Display.global.input.resume # XXX no resume() on IO::FileDescriptor
        puts "Resuming stdin (not implemented)"
      when "end"
        # Happens on at_exit already; doing it here too throws -EBADF in the at_exit handler.
        # Display.global.input.cooked!
        # Display.global.input.close
        puts "Ending stdin (not implemented)"
      else
        puts "Not resuming nor ending. Can also run test with argument 'resume' or 'end'."
      end

      exit
    end
  end

  s.render

  s.exec
end
