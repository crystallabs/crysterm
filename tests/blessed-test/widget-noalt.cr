require "../../src/crysterm"

# Port of Blessed's test/widget-noalt.js
# A centered List (items "one"/"two"/"three") with keyboard, vi_keys and mouse
# support. Item text is blue; the selected item gets a green background.
# Selecting an item destroys the screen; q / Ctrl-C quit.
include Crysterm
include Crysterm::Widgets

# Blessed's `noAlt: true` (don't switch to the alternate screen buffer)
# has no Crysterm equivalent, so it is dropped.
s = Window.new always_propagated_keys: [::Tput::Key::CtrlQ]

list = List.new(
  parent: s,
  align: ::Tput::AlignFlag::Center,
  mouse: true,
  # Crysterm's List enables key handling internally; there is no `keys:`
  # kwarg (it would collide with the value List forwards to its base), so
  # blessed's keys:true is implicit here.
  vi_keys: true,
  width: "50%",
  # blessed height:'shrink' -> shrink_to_fit
  shrink_to_fit: true,
  top: 5,
  left: 0,
  items: ["one", "two", "three"],
  styles: Styles.new(
    normal: Style.new(fg: "blue"),
    selected: Style.new(bg: "green"),
  ),
)

list.add_to_selection 0

list.on(Crysterm::Event::ItemSelected) do |e|
  s.destroy
  exit
end

list.focus

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

s.render

s.exec
