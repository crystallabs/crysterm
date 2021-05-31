require "../src/crysterm"

module Crysterm
  w = Window.new optimization: OptimizationFlag::SmartCSR # , auto_padding: true # (Already the default)

  b = Widget::Box.new(
    window: w,
    top: "center",
    left: "center",
    width: 20,
    height: 10,
    border: true,
  )

  b2 = Widget::Box.new(
    parent: b,
    top: 0,
    left: 0,
    width: 10,
    height: 5,
    border: true,
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

  w.display.exec
end
