require "../../src/crysterm"

include Crysterm
include Crysterm::Widgets
include Tput::Namespace

s = Window.new optimization: OptimizationFlag::SmartCSR

b = BigText.new \
  content: "Hello",
  # parse_tags: true,
  shrink_to_fit: true,
  width: "80%",

  style: Style.new(
    fg: "red",
    bg: "blue",
    bold: false,
    fill_char: '▒',
    border: BorderType::Solid,
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
