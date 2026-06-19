require "../src/crysterm"

class MyProg
  include Crysterm

  s = Screen.global

  # `Box` is one of the available widgets. It is a read-only space for
  # displaying text etc. In Qt terms, this is a Label.
  b = Widget::Box.new \
    top: 0,
    left: 0,
    width: "100%",
    height: "100%-2",
    content: "Content goes here. Press ENTER to start, then type things in.\n" +
             "Press ENTER to add line to main box. Ctrl+q to quit.",
    parse_tags: true,
    style: Style.new(fg: "yellow", bg: "blue", border: true),
    parent: s

  # User input box
  input = Widget::TextBox.new \
    top: "100%-2",
    left: 0,
    width: "100%",
    height: 1,
    style: Style.new(fg: "black", bg: "green"),
    parent: s

  input.focus

  # When q is pressed, exit the demo. All input first goes to the `Display`,
  # before being passed onto the focused widget, and then up its parent
  # tree. So attaching a handler to `Display` is the correct way to handle
  # the key press as early as possible.
  s.on(Event::KeyPress) do |e|
    if e.key == Tput::Key::CtrlQ
      exit
    end
  end

  # Handle the line being entered. The `TextBox` reads input while focused and,
  # on Enter, emits `Event::Submit` with the typed text and then gives up focus
  # (it is an input-on-focus widget). We append the line to the main box and
  # re-focus the input so the user can keep typing line after line; without the
  # re-focus the input would go dead after the first line.
  #
  # Note: use `Event::Submit` rather than a raw `Event::KeyPress` for Enter. The
  # widget's own Enter handling (which tears down and hands back focus) runs
  # *after* our key handler would, so re-focusing from a key handler is too
  # early to take effect. `Event::Submit` is emitted once that teardown is done.
  input.on(Event::Submit) do |e|
    c = e.value
    c = "~" if c == ""
    b.set_content b.content + c + "\n"
    input.value = ""
    input.focus
    s.render
  end

  s.exec
end
