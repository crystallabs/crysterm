require "../src/crysterm"

module Crysterm
  include Widget # Just for convenience, to not have to write e.g. `Screen`

  s = Screen.new

  b = Box.new(
    screen: s,
    border: BorderType::Line,
    style: Style.new(
      bg: "red",
      # TODO This part is not required in Blessed. See why is it required here and,
      # if it makes sense, return the behavior back to be compatible with Blessed.
      border: Style.new(
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

  s.on(Event::KeyPress) do |e|
    #STDERR.puts e.inspect
    if e.char == 'q'
      #e.accept!
      s.destroy
      exit
    end
  end

  s.render

  s.app.exec
end
