require "../src/crysterm"

module Crysterm
  s = Screen.new

  b = Widget::Box.new(
    top: "center",
    left: "center",
    width: "50%",
    height: 5,
    align: Tput::AlignFlag::Center,
    content: "Foobar.",
    style: Style.new(border: true)
  )

  s.append b

  s.on(Event::KeyPress) do |e|
    # STDERR.puts e.inspect
    if e.char == 'q'
      # e.accept!
      s.destroy
      exit
    end
  end

  s.display.exec
end
