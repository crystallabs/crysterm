require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

# Port of Blessed's test/widget-shadow.js
#
# Demonstrates drop shadows (`Style#shadow`): a full-screen background box, a
# static "under" box, and a centered draggable "over" box that casts a shadow
# over the others. Arrow keys nudge the over box; drag it with the mouse.

s = CT::Window.new optimization: CT::OptimizationFlag::SmartCSR,
  border_junctions: true,
  always_propagated_keys: [::Tput::Key::CtrlQ]

# Blessed uses a long Cicero passage; a short filler suffices here.
lorem = ([
  "Non eram nescius Brute cum quae summis ingeniis exquisitaque doctrina",
  "philosophi Graeco sermone tractavissent ea Latinis litteris mandaremus",
  "fore ut hic noster labor in varias reprehensiones incurreret nam quibusdam",
  "et iis quidem non admodum indoctis totum hoc displicet philosophari.",
] * 8).join(" ")

bg = CW::Box.new \
  parent: s,
  left: 0, top: 0, right: 0, bottom: 0,
  content: lorem,
  style: CT::Style.new(bg: "lightblue", shadow: true)

CW::Box.new \
  parent: s,
  left: 10, top: 4,
  width: "40%", height: "30%",
  parse_tags: true,
  style: CT::Style.new(bg: "yellow", border: true, shadow: true)

# blessed `style.transparent: true` → crysterm's `Style#alpha` (blends each cell
# with what's underneath via `Colors.blend`). 0.5 matches blessed's 50% mix.
over = CW::Box.new \
  parent: s,
  left: "center", top: "center",
  width: "50%", height: "50%",
  draggable: true,
  parse_tags: true,
  content: "{green-bg}{red-fg}{bold} --Drag Me-- {/}",
  style: CT::Style.new(bg: "red", border: true, shadow: true, opacity: 0.5)

over.focus

s.update

s.on(CT::Event::KeyPress) do |e|
  case e.key
  when ::Tput::Key::Left  then over.left = over.aleft - 2; s.update
  when ::Tput::Key::Right then over.left = over.aleft + 2; s.update
  when ::Tput::Key::Up    then over.top = over.atop - 1; s.update
  when ::Tput::Key::Down  then over.top = over.atop + 1; s.update
  else
    if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end
end

s.exec
