require "../src/crysterm"

class MyProg
  include Crysterm

  d = Display.new
  s = Screen.new display: d

  style1 = Style.new fg: "black", bg: "#729fcf", border: Style.new(fg: "black", bg: "#729fcf")
  style2 = Style.new fg: "black", bg: "magenta", border: Style.new(fg: "black", bg: "#729fcf"), transparency: true
  # style2 = Style.new fg: "white", bg: "#870087", border: Style.new(fg: "black", bg: "#870087", transparency: true), transparency: true
  style3 = Style.new fg: "black", "bg": "#729fcf", border: Style.new(fg: "black", bg: "#729fcf"), bar: Style.new(fg: "#d75f00")

  chat = Widget::TextArea.new \
    top: 0,
    left: 0,
    width: "100%",
    height: "100%-3",
    content: "Chat session ...",
    parse_tags: false,
    border: true,
    style: style1

  input = Widget::TextBox.new \
    top: "100%-4",
    left: 0,
    width: "100%-39",
    height: 3,
    border: true,
    style: style1
  input.on(Crysterm::Event::Submit) do |e|
    chat.set_content "#{chat.content}\n#{e.value}"
    input.value = ""
    s.render
    input.focus
  end

  members = Widget::List.new \
    top: 0,
    left: "100%-40",
    width: 40,
    height: "100%-3",
    border: true,
    # padding: Padding.new(left: 1),
    scrollbar: true,
    style: style2
  # padding: Padding.new( left: 1 ) # Triggers a visual bug? Possibly in combination with transparency?

  lag = Widget::ProgressBar.new \
    top: "100%-4",
    left: "100%-40",
    width: 40,
    height: 3,
    border: Border.new(type: BorderType::Line),
    content: "{center}Lag Indicator{/center}",
    parse_tags: true,
    filled: 10,
    style: style3

  s.append chat
  s.append members
  s.append lag
  s.append input

  input.focus

  # When q is pressed, exit the demo. All input first goes to the `Display`,
  # before being passed onto the focused widget, and then up its parent
  # tree. So attaching a handler to `Display` is the correct way to handle
  # the key press as early as possible.
  d.on(Event::KeyPress) do |e|
    case e.key
    when Tput::Key::CtrlQ
      exit
    when Tput::Key::Tab
      s.focus_next
    when Tput::Key::ShiftTab
      s.focus_prev
    end
  end

  #  # Just basic (suboptimal) way to handle enter pressed in the input box.
  #  # But well, livable for now.
  #  input.on(Event::KeyPress) do |e|
  #    if e.key == Tput::Key::Enter
  #      c = input.content
  #      c = "~" if c == ""
  #      chat.set_content chat.content + c + "\n"
  #      input.value = ""
  #      s.render
  #    end
  #  end

  spawn do
    id = 1
    loop do
      r = rand
      if r < 0.5
        members.append_item "{left}Member #{id}{/left}"
        id += 1
      else
        members.items[rand id]?.try do |item|
          members.remove_item item
        end
      end
      s.render
      sleep rand 2
      lag.filled = rand 100
      s.render
    end
  end

  d.exec
end
