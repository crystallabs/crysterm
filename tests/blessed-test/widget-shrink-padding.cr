require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

# Port of Blessed's test/widget-shrink-padding.js

s = CT::Window.new always_propagated_keys: [::Tput::Key::CtrlQ]

outer = CW::Box.new(
  parent: s,
  left: "center",
  top: "center",
  shrink_to_fit: true,
  style: CT::Style.new(
    bg: "green",
    padding: 1
  )
)

CW::Box.new(
  parent: outer,
  left: 0,
  top: 0,
  shrink_to_fit: true,
  content: "foobar",
  style: CT::Style.new(
    bg: "magenta"
  )
)

s.on(CT::Event::KeyPress) do |e|
  if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

s.update
s.exec
