require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

# Port of Blessed's test/widget-nowrap.js
# Width-60 box with wrapping disabled and tags enabled, content is this
# file's own source; lines longer than the box are clipped instead of wrapped.
# Blessed's `wrap: false` maps to crysterm's `wrap_content: false`.

s = CT::Window.new always_propagated_keys: [::Tput::Key::CtrlQ]

box = CW::Box.new(
  parent: s,
  width: 60,
  wrap_content: false,
  content: File.read(__FILE__)
)

box.focus

s.on(CT::Event::KeyPress) do |e|
  if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

s.update
s.exec
