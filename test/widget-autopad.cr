require "../src/crysterm"

module Crysterm
  include Widget # Just for convenience, to not have to write e.g. `Widget::Screen`

  s = Screen.new optimization: OptimizationFlag::SmartCSR #, auto_padding: true # (Already the default)

  b = Box.new(
    screen: s,
    top: "center",
    left: "center",
    width: 20,
    height: 10,
    border: true,
  )

  b2 = Box.new(
    parent: b,
    top: 0,
    left: 0,
    width: 10,
    height: 5,
    border: true,
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
