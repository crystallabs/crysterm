require "../src/crysterm"

module Crysterm
  w = Window.new

  b = Widget::Box.new(
    window: w,
    style: Style.new(
      bg: "blue",
    ),
    height: 5,
    top: "center",
    left: 0,
    width: 12,
    content: "{yellow-fg}line{/yellow-fg}{|}1"
  )

  w.on(Event::KeyPress) do |e|
    # STDERR.puts e.inspect
    if e.char == 'q'
      # e.accept!
      w.destroy
      exit
    end
  end

  w.render

  b.insert_bottom "{yellow-fg}line{/yellow-fg}{|}2"
  b.insert_top "{yellow-fg}line{/yellow-fg}{|}0"

  w.render

  sleep 2

  b.delete_top

  w.render

  w.display.exec
end
