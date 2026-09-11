require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

include Tput::Namespace

s = CT::Window.new optimization: CT::OptimizationFlag::SmartCSR

b = CW::BigText.new \
  content: "Hello",
  # parse_tags: true,
  shrink_to_fit: true,
  width: "80%",

  style: CT::Style.new(
    fg: "red",
    bg: "blue",
    bold: false,
    fill_char: '▒',
    border: CT::BorderType::Solid,
  )

s.append b
b.focus
s.update

s.on(CT::Event::KeyPress) do |e|
  e.accept
  if e.char == 'q'
    s.destroy
    exit
  end
end

s.exec
