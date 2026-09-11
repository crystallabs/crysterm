require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new

b = CW::Box.new(
  top: "center",
  left: "center",
  width: "50%",
  height: 5,
  align: Tput::AlignFlag::Center,
  content: "Foobar.",
  style: CT::Style.new(border: true)
)

s.append b

s.on(CT::Event::KeyPress) do |e|
  # STDERR.puts e.inspect
  if e.char == 'q'
    # e.accept
    s.destroy
    exit
  end
end

s.exec
