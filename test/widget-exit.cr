require "../src/crysterm"

module Crysterm
  include Widget # Just for convenience, to not have to write e.g. `Widget::Screen`

  s = Screen.new lock_keys: true, ignore_locked: [ Tput::Key::CtrlQ ]

  b = Box.new(
    screen: s,
    top: "center",
    left: "center",
    width: "70%",
    height: "resizable",
    border: true,
    content: "Press Ctrl+q to quit. It should work even though screen's keys are locked."
  )

  s.on(Event::KeyPress) do |e|
    if e.key == Tput::Key::CtrlQ
      s.destroy
      
      case ARGV[0]?
      when "resume"
        #App.global.input.resume # XXX no resume() on IO::FileDescriptor
        puts "Resuming stdin (not implemented!)"
      when "end"
        App.global.input.cooked!
        App.global.input.close
        puts "Ending stdin"
      else
        puts "Not resuming nor ending. Can also run test with argument 'resume' or 'end'."
      end

      exit
    end
  end

  s.render

  s.app.exec
end
