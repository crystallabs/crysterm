require "../src/crysterm"

module Crysterm
  include Tput::Namespace

  w = Window.new optimization: OptimizationFlag::SmartCSR

  b = Widget::BigText.new \
    content: "Hello",
    # parse_tags: true,
    resizable: true,
    width: "80%",
    height: "resizable",
    border: BorderType::Line,

    # shadow: true,
    style: Style.new(
      fg: "red",
      bg: "blue",
      bold: false,
      # fchar: ' ',
      char: '\u2592',
    )

  w.append b
  b.focus
  w.render

  w.on(Event::KeyPress) do |e|
    e.accept!
    if e.char == 'q'
      w.destroy
      exit
    end
  end

  sleep
end
