require "../../src/crysterm"

# Port of Blessed's test/widget-nowrap.js
# A width-60 box with wrapping disabled and tags enabled, whose content is
# this example file's own source. Lines longer than the box are clipped
# instead of wrapped.
# NOTE: Blessed's `wrap: false` maps to crysterm's `wrap_content: false`.
module Crysterm
  s = Window.new always_propagate: [::Tput::Key::CtrlQ]

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
end
