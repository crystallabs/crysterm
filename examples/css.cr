require "../src/crysterm"

# Demonstrates styling widgets via CSS instead of inline `Style` objects.
#
# The same look as `hello.cr`, but the colors/border come from a stylesheet
# matched against the widget tree. Note:
#   * `Box` matches every Box and its subclasses (widget name as selector);
#   * `Button` + `:focus` restyle the button when focused (press Tab);
#   * `#hello` targets a specific widget by its `css_id`.
class MyProg
  include Crysterm

  s = Screen.new title: "CSS demo"

  s.stylesheet = <<-CSS
    Box {
      color: white;
      background-color: #222244;
    }
    #hello {
      color: yellow;
      background-color: blue;
      border: solid cyan;
    }
    Button {
      color: black;
      background-color: gray;
      border: solid white;
    }
    Button:focus {
      background-color: green;
      font-weight: bold;
    }
  CSS

  box = Widget::Box.new \
    parent: s,
    top: "center",
    left: "center",
    width: 30,
    height: 7,
    content: "{center}Styled by {bold}CSS{/bold}!\nPress Tab, then q to quit.{/center}",
    parse_tags: true
  box.css_id = "hello"

  button = Widget::Button.new \
    parent: s,
    top: "center+5",
    left: "center",
    width: 14,
    height: 3,
    content: "{center}OK{/center}",
    parse_tags: true
  button.focus

  s.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == Tput::Key::CtrlQ
      s.destroy
      exit
    end
  end

  s.exec
end
