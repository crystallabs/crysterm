require "../../src/crysterm"

include Crysterm

d = Display.new
s = Screen.new display: d

w = Widget::Box.new \
  parent: s,
  top: 0,
  left: 0,
  resizable: true,
  content: "Hello, World!",
  parse_tags: false,
  style: Style.new(fg: "yellow", bg: "blue"),
  border: true

s.on(Event::KeyPress) { |e| exit }

s.on(Event::Rendered) {
  STDERR.puts w.screenshot
  exit if ARGV.includes? "-exit"
}

s.render

sleep
