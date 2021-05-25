require "../src/crysterm"

module Crysterm
  include Widget # Just for convenience, to not have to write e.g. `Widget::Screen`

  s = Screen.new

  b = Box.new(
    screen: s,
    style: Style.new(
      bg: "blue",
    ),
    height: 5,
    top: "center",
    left: 0,
    width: 12,
    content: "{yellow-fg}line{/yellow-fg}{|}1"
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

  b.insert_bottom "{yellow-fg}line{/yellow-fg}{|}2"
  b.insert_top "{yellow-fg}line{/yellow-fg}{|}0"
 
  s.render

  sleep 2

  b.delete_top

  s.render
 
  s.app.exec
end
