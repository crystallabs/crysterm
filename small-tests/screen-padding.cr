require "../src/crysterm"

class MyProg
  include Crysterm

  s = Screen.new padding: 4

  b = Widget::Box.new width: "100%", height: "100%", style: Style.new(border: true)
  s.append b

  # When q is pressed, exit the demo.
  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.exec
end
