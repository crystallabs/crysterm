require "../src/crysterm"


include Crysterm

def draw(s : Screen)
  8.times do |x|
    8.times do |y|
      s.fill_region(Widget.sattr(Namespace::Style.new, x, y), '0', x, x+1, (y*2), (y*2)+1)
      s.fill_region(Widget.sattr(Namespace::Style.new, x+8, y), '0', x+8, x+8+1, (y*2), (y*2)+1)
      s.fill_region(Widget.sattr(Namespace::Style.new, x, y+8), '0', x, x+1, (y*2)+1, (y*2)+2)
      s.fill_region(Widget.sattr(Namespace::Style.new, x+8, y+8), '0', x+8, x+8+1, (y*2)+1, (y*2)+2)
    end
  end
end

# `Display` is a phyiscal device (terminal hardware or emulator).
# It can be instantiated manually as shown, or for quick coding it can be
# skipped and it will be created automatically when needed.
d = Display.new

# `Screen` is a full-screen surface which contains visual elements (Widgets),
# on which graphics is rendered, and which is then drawn onto the terminal.
# An app can have multiple screens, but only one can be showing at a time.
s = Screen.new display: d

draw(s)

s.on(Event::Resize) do
  draw(s)
end

# When q is pressed, exit the demo.
s.on(Event::KeyPress) do |e|
  if e.char == 'q'
    exit
  end
end

spawn do
  loop do
    sleep 1
    s.render
  end
end

d.exec
