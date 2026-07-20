require "../../src/crysterm"

# Port of Blessed's test/widget-nowrap.js
# Width-60 box with wrapping disabled and tags enabled, content is this
# file's own source; lines longer than the box are clipped instead of wrapped.
# Blessed's `wrap: false` maps to crysterm's `wrap_content: false`.
include Crysterm

s = Window.new always_propagated_keys: [::Tput::Key::CtrlQ]

box = Widget::Box.new(
  parent: s,
  width: 60,
  wrap_content: false,
  parse_tags: true,
  content: File.read(__FILE__)
)

box.focus

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

s.render
s.exec
