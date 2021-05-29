require "../src/crysterm"

module Crysterm
  w = Window.new optimization: OptimizationFlag::SmartCSR, auto_padding: false

  b = Widget::Box.new(
    window: w,
    top: "center",
    left: "center",
    width: "50%",
    height: 5,
    align: Tput::AlignFlag::Center,
    valign: Tput::AlignFlag::Center,
    # valign: AlignFlag::Bottom,
    content: "Foobar.",
    border: true
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

  w.screen.exec
end
