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
# The bottom-right box is a *hover* target: it reacts to the pointer entering
# (`Event::MouseOver`), moving within it (`Event::MouseMove`) and leaving
# (`Event::MouseOut`). Hover events go only to the topmost widget under the
# pointer.
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
    height: "60%",
    content: "Move / click / scroll the mouse. Press q to quit.",
    scrollable: true,
    style: Style.new(fg: "white", bg: "black", border: true)

  click_box = Widget::Box.new \
    parent: s,
    name: "click",
    top: "60%",
    left: 4,
    width: 30,
    height: 6,
    content: "{center}Click me!{/center}",
    parse_tags: true,
    style: Style.new(fg: "black", bg: "green", border: true)

  hover_box = Widget::Box.new \
    parent: s,
    name: "hover",
    top: "60%",
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

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.exec
end
