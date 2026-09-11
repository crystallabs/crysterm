require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new optimization: CT::OptimizationFlag::SmartCSR

b = CW::Box.new(
  top: "center",
  left: "center",
  width: 20,
  height: 10,
  style: CT::Style.new(border: true),
)

# Must add the Widget to screen in this way for the moment
s.append b

b2 = CW::Box.new(
  parent: b,
  top: 0,
  left: 0,
  width: 10,
  height: 5,
  style: CT::Style.new(border: true),
)

s.on(CT::Event::KeyPress) do |e|
  # STDERR.puts e.inspect
  if e.char == 'q'
    # e.accept
    s.destroy
    exit
  end
end

s.update

s.exec
