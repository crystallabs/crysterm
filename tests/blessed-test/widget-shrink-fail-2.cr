require "../../src/crysterm"

# Port of Blessed's test/widget-shrink-fail-2.js
#
# An outer scrollable `tab` box containing a single shrink_to_fit (blessed 'shrink')
# Text whose content is a pretty-printed sample object.
module Crysterm
  s = Window.new always_propagated_keys: [::Tput::Key::CtrlQ]

  tab = Widget::ScrollableBox.new \
    parent: s,
    top: 2,
    left: 0,
    right: 0,
    bottom: 0,
    scrollable: true,
    keys: true,
    vi_keys: true,
    always_scroll: true,
    scrollbar: true

  # NOTE: blessed used `require('util').inspect(process, null, 6)`, which is
  # Node-only and unportable. We pretty-print a sample Crystal object instead.
  sample = {"name" => "crysterm", "nums" => [1, 2, 3], "nested" => {"a" => true, "b" => "two"}}

  data = Widget::Text.new \
    parent: tab,
    top: 0,
    left: 3,
    # NOTE: blessed height:'shrink' / width:'shrink' -> shrink_to_fit: true
    shrink_to_fit: true,
    content: "",
    parse_tags: true

  data.set_content sample.pretty_inspect

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.render
  s.exec
end
