require "../src/crysterm"

module Crysterm
  include Widget

  s = Screen.new optimization: OptimizationFlag::SmartCSR

  b = BigText.new \
    screen: s,
    content: "Hello",
    resizable: true,
    width: "80%",
    height: "resizable",
    border: BorderType::Line,

    #shadow: true,
    style: Style.new(
      fg: "red",
      bg: "blue",
      bold: false,
      #fchar: ' ',
      char: '\u2592',
    )

  s.render

  s.on(Event::KeyPress) do |e|
    e.accept!
    if e.char == 'q'
      s.destroy
      exit
    end
  end

  sleep
end
