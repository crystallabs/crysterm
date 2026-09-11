require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new

b = CW::Box.new(
  style: CT::Style.new(
    bg: "red",
    # TODO This part is not required in Blessed. See why is it required here and,
    # if it makes sense, return the behavior back to be compatible with Blessed.
    border: CT::Border.new(
      bg: "black"
    ),
    padding: 2
  ),
  content: "hello world\nhi",
  align: Tput::AlignFlag::Center,
  top: "center",
  left: "center",
  width: 22,
  height: 10
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

s.update

s.exec
