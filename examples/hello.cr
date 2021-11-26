require "../src/crysterm"

class MyProg
  include Crysterm

  # `Display` is a phyiscal device (terminal hardware or emulator).
  # It can be instantiated manually as shown, or for quick coding it can be
  # skipped and it will be created automatically when needed.
  d = Display.new

  # `Screen` is a full-screen surface which contains visual elements (Widgets),
  # on which graphics is rendered, and which is then drawn onto the terminal.
  # An app can have multiple screens, but only one can be showing at a time.
  s = Screen.new display: d

  # `Box` is one of the available widgets. It is a read-only space for
  # displaying text etc. In Qt terms, this is a Label.
  b = Widget::Box.new \
    parent: s,
    name: "helloworld box", # Symbolic name
    top: "center",          # Can also be 10, "50%", or "50%-10"
    left: "center",         # Same as above
    width: 20,              # ditto
    height: 5,              # ditto
    content: "{center}'Hello {bold}world{/bold}!'\nPress q to quit.{/center}",
    parse_tags: true, # Parse {} tags within content (default already is true)
    style: Style.new(fg: "yellow", bg: "blue"),
    border: true # Can be styled, or 'true' for default look

    # Add box to the Screen, because it is a top-level widget without a parent.
    # If there is a parent, you would call `Widget#append` on the parent object,
    # not on the screen.

  b.focus

  # # Just for show, display the cursor, and later move its position along with
  # # the position of the created box.
  # s.show_cursor
  # s.tput.cursor_shape Tput::CursorShape::Block, blink: true
  # s.tput.cursor_color Tput::Color::Goldenrod1

  # When q is pressed, exit the demo.
  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == Tput::Key::CtrlQ
      d.destroy
      exit
    end
  end

  spawn do
    loop do
      sleep 2
      b.rtop = rand(s.aheight - b.aheight - 1) + 1
      b.rleft = rand(s.awidth - b.awidth)

      # s.tput.cursor_pos b.top, b.left + b.width//2

      s.render
    end
  end

  d.exec
end
