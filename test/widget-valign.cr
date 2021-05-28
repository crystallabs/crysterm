require "../src/crysterm"

module Crysterm
  include Widget # Just for convenience, to not have to write e.g. `Screen`

  s = Screen.new optimization: OptimizationFlag::SmartCSR, auto_padding: false

  b = Box.new(
    screen: s,
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
