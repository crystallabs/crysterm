require "../src/crysterm"

module Crysterm
  s = Screen.new optimization: OptimizationFlag::SmartCSR

  b = Widget::Box.new(
    top: "center",
    left: "center",
    width: 20,
    height: 10,
    border: true,
  )

  # Must add the Widget to screen in this way for the moment
  s.append b

  b2 = Widget::Box.new(
    parent: b,
    top: 0,
    left: 0,
    width: 10,
    height: 5,
    border: true,
  )

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
