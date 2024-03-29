require "../src/crysterm"

module Crysterm
  include Tput::Namespace

  s = Screen.new optimization: OptimizationFlag::SmartCSR

  b = Widget::BigText.new \
    content: "Hello",
    # parse_tags: true,
    resizable: true,
    width: "80%",

    style: Style.new(
      fg: "red",
      bg: "blue",
      bold: false,
      # fchar: ' ',
      char: '\u2592',
      border: BorderType::Line,
    )

  s.append b
  b.focus
  s.render

  s.on(Event::KeyPress) do |e|
    e.accept
    if e.char == 'q'
      s.destroy
      exit
    end
  end

  s.exec
end
