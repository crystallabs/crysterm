require "../src/crysterm"

# Drag-and-drop demo.
#
# Crysterm's drag-and-drop is one input-agnostic gesture driven by two sensors:
#
#   * **Mouse:** press on a draggable widget and move to drag; release to drop.
#     Hold **Ctrl** to Copy or **Shift** to Move (the desktop convention).
#   * **Keyboard:** Tab to a draggable widget, press **Space** to pick it up,
#     then **Tab** to choose a target / **arrow keys** to nudge a free box,
#     **Space** (or Enter) to drop, **Esc** to cancel.
#
# Both drive the same `DragStart`/`Drag`/`DragEnter`/`DragOver`/`Drop`/`DragEnd`
# events, so the widgets below are written once and work with either input.
#
# Two flavors are shown:
#   1. **Reposition** ("self-move") — the green box follows the drag anchor.
#   2. **Data transfer** — the yellow source hands a typed payload to the blue
#      drop zone, which opts in and consumes it. A "ghost" follows the pointer.
#
# The **focused** widget shows a red border. The status line at the top is wired
# to the engine's announce hook (a "live region" for keyboard users).
#
# Press q (or Ctrl-Q) to quit.
class DragDemo
  include Crysterm

  s = Screen.new title: "Drag & drop demo"

  INSTRUCTIONS = "Mouse: drag the boxes (Ctrl=copy, Shift=move).   " \
                 "Keyboard: Tab, Space to pick up, Tab/arrows to move, Space to drop, Esc to cancel.   q to quit."

  info = Widget::Box.new \
    parent: s,
    top: 0,
    left: 0,
    width: "100%",
    height: 5,
    content: INSTRUCTIONS,
    parse_tags: true,
    style: Style.new(fg: "white", bg: "black", border: true)

  status = ""
  set_status = ->(msg : String) do
    status = msg
    info.content = "#{INSTRUCTIONS}\n{bold}status:{/bold} #{msg}"
    s.render
  end

  # Live region: route engine announcements to the status line.
  s.drag_announce = set_status

  # --- 1. Reposition: a free-floating box that follows the drag anchor. ---
  free = Widget::Box.new \
    parent: s,
    name: "Free box",
    top: 7,
    left: 4,
    width: 26,
    height: 5,
    content: "{center}Move me!\n(reposition){/center}",
    parse_tags: true,
    draggable: true, # installs default self-move behavior
    keys: true,      # focusable, so it can also be picked up by keyboard
    style: Style.new(fg: "black", bg: "green", border: true)

  # --- 2. Data transfer: a source that hands a payload to a drop zone. ---
  source = Widget::Box.new \
    parent: s,
    name: "Parcel source",
    top: 7,
    right: 4,
    width: 26,
    height: 5,
    content: "{center}Drag me onto\nthe drop zone{/center}",
    parse_tags: true,
    keys: true,
    style: Style.new(fg: "black", bg: "yellow", border: true)

  # Drag source, but NOT self-moving: it stays put and transfers data instead.
  source.enable_drag reposition: false
  source.on(Event::DragStart) do |e|
    e.data["text/plain"] = "parcel ##{rand(100)}"
  end

  drop_count = 0
  drop_zone = Widget::Box.new \
    parent: s,
    name: "Drop zone",
    top: 14,
    left: "center",
    width: 34,
    height: 6,
    content: "{center}Drop zone\n(waiting…){/center}",
    parse_tags: true,
    keys: true,
    style: Style.new(fg: "white", bg: "blue", border: true)

  # The drop zone opts in (only for payloads it understands) and reacts.
  accept_if_ok = ->(e : Event::DragEvent) do
    e.accept if e.data.has? "text/plain"
  end
  drop_zone.on(Event::DragEnter) { |e| accept_if_ok.call e; drop_zone.style.bg = "magenta"; s.render }
  drop_zone.on(Event::DragOver) { |e| accept_if_ok.call e }
  drop_zone.on(Event::DragLeave) { drop_zone.style.bg = "blue"; s.render }
  drop_zone.on(Event::Drop) do |e|
    drop_count += 1
    drop_zone.style.bg = "blue"
    drop_zone.content = "{center}#{e.data.action}: #{e.data["text/plain"]}\n(#{drop_count} total){/center}"
    s.render
  end

  # --- Focused widget gets a red border so it's obvious which one is active. ---
  {free, source, drop_zone}.each do |w|
    base = w.style.border.fg
    w.on(Event::Focus) { w.style.border.fg = "red"; s.render }
    w.on(Event::Blur) { w.style.border.fg = base; s.render }
  end

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.exec
end
