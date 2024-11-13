require "../../src/crysterm"

include Crysterm

s = Screen.new

w = Widget::Box.new \
  parent: s,
  top: 0,
  left: 0,
  resizable: true,
  content: "Hello, World!",
  parse_tags: false,
  style: Style.new(fg: "yellow", bg: "blue", border: true)

s.on(Event::KeyPress) { |_| exit }

s.on(Event::Rendered) {
  if ARGV.includes? "--test-auto"
    STDERR.puts w.snapshot
    exit
  end
}

s.render

sleep
