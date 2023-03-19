require "../src/crysterm"

module Crysterm
  s = Screen.new

  b = Widget::Box.new(
    style: Style.new(
      bg: "red",
      # TODO This part is not required in Blessed. See why is it required here and,
      # if it makes sense, return the behavior back to be compatible with Blessed.
      border: Border.new(
        bg: "black"
      )
    ),
    content: "hello world\nhi",
    align: Tput::AlignFlag::Center,
    top: "center",
    left: "center",
    width: 22,
    height: 10,
    padding: 2
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

  s.render

  s.display.exec
end
