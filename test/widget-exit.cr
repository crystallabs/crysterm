require "../src/crysterm"

module Crysterm
  include Widgets # Just for convenience, to not have to write e.g. `Widget::Box`

  s = Screen.new propagating_keys: false, always_propagate: [Tput::Key::CtrlQ]

  b = Box.new(
    screen: s,
    top: "center",
    left: "center",
    width: "70%",
    height: "resizable",
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
        # This will happen on at_exit; not needed to do here.
        # Well, can do both, but then at_exit handler will throw -EBADF
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

  s.display.exec
end
