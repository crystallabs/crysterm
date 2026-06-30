require "../../src/crysterm"

# Port of Blessed's test/widget-shadow.js
#
# Demonstrates drop shadows (`Style#shadow`): a full-screen background box, a
# static "under" box, and a centered draggable "over" box that casts a shadow
# over the others. Arrow keys nudge the over box; drag it with the mouse.
module Crysterm
  s = Window.new optimization: OptimizationFlag::SmartCSR,
    dock_borders: true,
    always_propagate: [::Tput::Key::CtrlQ]

  # NOTE: blessed shortens to a long Cicero passage; a short filler suffices to
  # show the background under the shadows.
  lorem = ([
    "Non eram nescius Brute cum quae summis ingeniis exquisitaque doctrina",
    "philosophi Graeco sermone tractavissent ea Latinis litteris mandaremus",
    "fore ut hic noster labor in varias reprehensiones incurreret nam quibusdam",
    "et iis quidem non admodum indoctis totum hoc displicet philosophari.",
  ] * 8).join(" ")

  bg = Widget::Box.new \
    parent: s,
    left: 0, top: 0, right: 0, bottom: 0,
    content: lorem,
    style: Style.new(bg: "lightblue", shadow: true)

  Widget::Box.new \
    parent: s,
    left: 10, top: 4,
    width: "40%", height: "30%",
    parse_tags: true,
    style: Style.new(bg: "yellow", border: true, shadow: true)

  # blessed `style.transparent: true` → crysterm's `Style#alpha` (the render blends
  # each cell with what's underneath via `Colors.blend`). `0.5` matches blessed's
  # 50% mix, so the yellow box, its shadow, and the blue background text show
  # through the red window.
  over = Widget::Box.new \
    parent: s,
    left: "center", top: "center",
    width: "50%", height: "50%",
    draggable: true,
    parse_tags: true,
    content: "{green-bg}{red-fg}{bold} --Drag Me-- {/}",
    style: Style.new(bg: "red", border: true, shadow: true, alpha: 0.5)

  over.focus

  s.render

  s.on(Event::KeyPress) do |e|
    case e.key
    when ::Tput::Key::Left  then over.left = over.aleft - 2; s.render
    when ::Tput::Key::Right then over.left = over.aleft + 2; s.render
    when ::Tput::Key::Up    then over.top = over.atop - 1; s.render
    when ::Tput::Key::Down  then over.top = over.atop + 1; s.render
    else
      if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
        s.destroy
        exit
      end
    end
  end

  s.exec
end
