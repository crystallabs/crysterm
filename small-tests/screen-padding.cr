require "../src/crysterm"

class MyProg
  include Crysterm

  d = Display.new
  s = Screen.new display: d, padding: 4

  b = Widget::Box.new width: "100%", height: "100%", border: true
  s.append b

  # When q is pressed, exit the demo.
  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == Tput::Key::CtrlQ
      d.destroy
      exit
    end
  end

  d.exec
end
