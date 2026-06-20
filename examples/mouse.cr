require "../src/crysterm"

# Mouse demo.
#
# Move the mouse, click, drag and scroll the wheel over the terminal. The top
# box logs every mouse event the screen receives (from either the terminal's
# xterm reporting or, on a Linux console, the `gpm` daemon — both arrive through
# the same `Event::Mouse`).
#
# The bottom-left box is a *click* target: clicking it emits `Event::Click` and
# flips its colour.
#
# The middle-right box is a *hover* target: it reacts to the pointer entering
# (`Event::MouseOver`), moving within it (`Event::MouseMove`) and leaving
# (`Event::MouseOut`). Hover events go only to the topmost widget under the
# pointer.
#
# The two partially overlapping boxes at the bottom demonstrate z-ordering:
# whichever one the pointer hovers over is brought to the front (`Widget#front!`)
# after a short delay — provided the pointer is still over it. Because mouse
# hit-testing follows the render/z order, raising a box also makes it the hit
# target in the overlap region.
#
# Press q (or Ctrl-Q) to quit.
class MouseDemo
  include Crysterm

  s = Screen.new title: "Mouse demo"

  log = Widget::Box.new \
    parent: s,
    name: "log",
    top: 0,
    left: 0,
    width: "100%",
    height: "45%",
    content: "Move / click / scroll the mouse. Press q to quit.",
    scrollable: true,
    style: Style.new(fg: "white", bg: "black", border: true)

  click_box = Widget::Box.new \
    parent: s,
    name: "click",
    top: "47%",
    left: 4,
    width: 30,
    height: 6,
    content: "{center}Click me!{/center}",
    parse_tags: true,
    style: Style.new(fg: "black", bg: "green", border: true)

  hover_box = Widget::Box.new \
    parent: s,
    name: "hover",
    top: "47%",
    right: 4,
    width: 30,
    height: 6,
    content: "{center}Hover me!{/center}",
    parse_tags: true,
    style: Style.new(fg: "black", bg: "blue", border: true)

  # Opt both widgets into mouse input. `Screen#insert` only auto-registers a
  # widget that is already `clickable?` at insert time; we set it afterwards, so
  # register explicitly.
  {click_box, hover_box}.each do |w|
    w.clickable = true
    s.register_clickable w
  end

  lines = [] of String
  add_log = ->(text : String) {
    lines << text
    lines.shift if lines.size > (log.aheight - 2)
    log.content = lines.join '\n'
    s.render
  }

  # Every mouse event on the screen (regardless of source) lands here.
  s.on(Event::Mouse) do |e|
    add_log.call "#{e.action} #{e.button} @ #{e.x},#{e.y}" \
                 "#{e.shift? ? " +shift" : ""}#{e.ctrl? ? " +ctrl" : ""}#{e.meta? ? " +meta" : ""}"
  end

  # --- Click target: a click flips its colour. ---
  green = true
  click_box.on(Event::Click) do
    green = !green
    click_box.style.bg = green ? "green" : "red"
    s.render
  end

  # --- Hover target: react to hover in / hovering / hover out. ---
  hover_box.on(Event::MouseOver) do |e|
    hover_box.style.bg = "magenta"
    hover_box.content = "{center}Hovering in!{/center}"
    add_log.call "hover IN  (hover box) @ #{e.x},#{e.y}"
    s.render
  end

  hover_box.on(Event::MouseMove) do |e|
    hover_box.content = "{center}Hovering @ #{e.x},#{e.y}{/center}"
    s.render
  end

  hover_box.on(Event::MouseOut) do |e|
    hover_box.style.bg = "blue"
    hover_box.content = "{center}Hover me!{/center}"
    add_log.call "hover OUT (hover box) @ #{e.x},#{e.y}"
    s.render
  end

  # --- Two partially overlapping boxes: hover raises to front after a delay. ---
  RAISE_DELAY = 0.5.seconds

  raise_a = Widget::Box.new \
    parent: s,
    name: "raise_a",
    top: "70%",
    left: "28%",
    width: 32,
    height: 7,
    content: "{center}Box A\n\nhover to raise me{/center}",
    parse_tags: true,
    style: Style.new(fg: "black", bg: "cyan", border: true)

  # Added after A, so B starts on top (later in the children array = drawn last).
  raise_b = Widget::Box.new \
    parent: s,
    name: "raise_b",
    top: "70%+3",
    left: "28%+16",
    width: 32,
    height: 7,
    content: "{center}Box B\n\nhover to raise me{/center}",
    parse_tags: true,
    style: Style.new(fg: "black", bg: "yellow", border: true)

  {raise_a, raise_b}.each do |bx|
    bx.clickable = true
    s.register_clickable bx

    name = bx.name

    # On hover-in, wait a moment; if the pointer is still over this box (it is
    # the topmost hovered widget), bring it to the front.
    bx.on(Event::MouseOver) do
      spawn do
        sleep RAISE_DELAY
        if s.hovered == bx
          bx.front!
          add_log.call "raised #{name} to front"
          s.render
        end
      end
    end
  end

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.exec
end
