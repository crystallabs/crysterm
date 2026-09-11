require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new

b = CW::Box.new(
  style: CT::Style.new(
    bg: "blue",
  ),
  parse_tags: true,
  height: 5,
  top: "center",
  left: 0,
  width: 12,
  content: "{yellow-fg}line{/yellow-fg}{|}1"
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

b.insert_bottom "{yellow-fg}line{/yellow-fg}{|}2"
b.insert_top "{yellow-fg}line{/yellow-fg}{|}0"

s.update

sleep 2.seconds

b.delete_top

s.update

s.exec
