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

  # Just basic (suboptimal) way to handle enter pressed in the input box.
  # But well, livable for nos.
  input.on(Event::KeyPress) do |e|
    if e.key == Tput::Key::Enter
      c = input.content
      c = "~" if c == ""
      b.set_content b.content + c + "\n"
      input.value = ""
      s.render
    end
  end

  s.exec
end
