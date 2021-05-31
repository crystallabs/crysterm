require "../src/crysterm"

class MyProg
  include Crysterm

  # `Display` is a phyiscal device (terminal hardware or emulator).
  # It can be instantiated manually as shown, or for quick coding it can be
  # skipped and it will be created automatically when needed.
  s = Display.new

  # `Screen` is a full-screen surface which contains visual elements (Widgets),
  # on which graphics is rendered, and which is then drawn onto the terminal.
  # An app can have multiple screens, but only one can be showing at a time.
  w = Screen.new display: s

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
    style: Style.new(fg: "yellow", bg: "blue"),
    border: true # Can be styled, or 'true' for default look

  # User input box
  input = Widget::TextBox.new \
    top: "100%-2",
    left: 0,
    width: "100%",
    height: 1,
    style: Style.new(fg: "black", bg: "green")

  w.append b
  w.append input

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
  # But well, livable for now.
  input.on(Event::KeyPress) do |e|
    if e.key == Tput::Key::Enter
      c = input.content
      c = "~" if c == ""
      b.content += c + "\n"
      input.value= ""
      w.render
    end
  end

  s.exec
end
