require "../src/crysterm"

module Crysterm
  include Tput::Namespace

  s = Screen.new
  b = layout = Widget::Layout.new(
    # parent: s,
    top: 0,
    left: 0,
    # width: "50%",
    # height: "50%",
    # border: BorderType::Line,
    layout: LayoutType::Grid,
    overflow: Overflow::Ignore,
    style: Style.new(
      bg: "black",
    )
  )

  # b.focus
  s.append b

  box = Widget::Box.new(
    parent: layout,
    width: 36,
    height: 18,
    border: BorderType::Line,
    content: "Plain box with some content."
  )

  button = Widget::Button.new(
    parent: layout,
    width: 36,
    height: 3,
    border: BorderType::Line,
    align: AlignFlag::HCenter,
    content: "Click me, I am a button.",
    shadow: true,
    style: Style.new(
      "bg": "blue",
      "fg": "yellow",
      border: Style.new(
        "bg": "blue"
      )
    )
  )

  checkboxes = Widget::Box.new(
    parent: layout,
    width: 18,
    height: 18,
    border: BorderType::Bg,
  )
  checkbox1 = Widget::Checkbox.new parent: checkboxes, content: "Checkbox 1", top: 0
  checkbox2 = Widget::Checkbox.new parent: checkboxes, content: "Checkbox 2", top: 2
  checkbox3 = Widget::Checkbox.new parent: checkboxes, content: "Checkbox 3", top: 4
  checkbox4 = Widget::Checkbox.new parent: checkboxes, content: "Checkbox 4", top: 6

  radioset = Widget::RadioSet.new parent: layout, width: 20, height: 18
  radio1 = Widget::RadioButton.new parent: radioset, content: "Radio button 1", top: 1
  radio2 = Widget::RadioButton.new parent: radioset, content: "Radio button 2", top: 3
  radio3 = Widget::RadioButton.new parent: radioset, content: "Radio button 3", top: 5
  radio4 = Widget::RadioButton.new parent: radioset, content: "Radio button 4", top: 7

  progressbar = Widget::ProgressBar.new \
    parent: layout,
    content: "{center}Progress bar{/center}",
    filled: 50,
    width: 36,
    height: 3,
    # padding: 1,
    border: Border.new(type: BorderType::Line),
    shadow: true,
    style: Style.new(
      fg: "yellow",
      bg: "magenta",
      border: Style.new(
        fg: "#ffffff"
      ),
    )

  loading = Widget::Loading.new \
    parent: layout,
    align: AlignFlag::HCenter,
    width: 36,
    height: 18,
    icons: ["Preparing", "Loading", "Processing", "Saving", "Analyzing"],
    content: "Please wait...",
    border: Border.new(type: BorderType::Line),
    style: Style.new(transparent: true, fg: "white", bg: "black", border: Style.new(fg: "white", bg: "black"))

  question = Widget::Question.new \
    parent: layout,
    content: "Question: {bold}HOT{/bold} or NOT?",
    # hidden: false,
    parse_tags: true,
    width: 36,
    height: 9,
    border: Border.new(type: BorderType::Line),
    shadow: true,
    style: Style.new(
      transparent: true,
      fg: "yellow",
      bg: "magenta",
      border: Style.new(
        fg: "#ffffff"
      ),
    )
  question.ask { }

  # overlayimage = Widget::OverlayImage.new \
  #  parent: layout,
  #  width: 36,
  #  height: 18,
  #  border: Border.new(type: BorderType::Line),
  #  shadow: false,
  #  style: Style.new(
  #    fg: "yellow",
  #    bg: "magenta",
  #    border: Style.new(
  #      fg: "#ffffff"
  #    ),
  #  )

  bigtext = Widget::BigText.new(
    parent: layout,
    width: 36,
    height: 18,
    border: BorderType::Line,
    content: "Big"
  )

  textarea = Widget::TextArea.new(
    parent: layout,
    width: 36,
    input_on_focus: true,
    height: 18,
    border: BorderType::Line,
    content: ""
  )

  textbox = Widget::TextBox.new(
    parent: layout,
    width: 36,
    height: 3,
    border: BorderType::Line,
    content: "TextBox. One-line element."
  )

  boxtp2 = Widget::Box.new(
    # parent: s,
    width: 60,
    height: 16,
    top: 24,
    left: 160,
    border: BorderType::Bg,
    content: "Hello, World! See translucency and shadow.",
    style: Style.new("bg": "#870087")
  )
  boxtp1 = Widget::Box.new(
    # parent: s,
    top: 20,
    left: 150,
    width: 60,
    height: 14,
    border: BorderType::Line,
    content: "See indeed.",
    shadow: true,
    style: Style.new("bg": "#729fcf", transparent: true)
  )
  s.append boxtp2
  s.append boxtp1

  loading2 = Widget::Loading.new \
    parent: layout,
    align: AlignFlag::Right,
    compact: true,
    interval: 0.2.seconds,
    width: 36,
    height: 3,
    content: "In progress!...",
    border: Border.new(type: BorderType::Line)

  s.on(Event::KeyPress) do |e|
    # e.accept!
    STDERR.puts e.inspect
    if e.char == 'q'
      exit
    end
  end

  s.render

  textv = "TextArea. This is a multi-line user input enabled widget with automatic content wrapping. There is a lot of text that can fit it, when the terminal doesn't use too big font."
  textboxv = " This will add more text to textbox and always show only visible portion."

  #textarea.focus
  loading.start
  loading2.start
  i = 0
  spawn do
    loop do
      [checkbox1, checkbox2, checkbox3, checkbox4][i % 4].toggle
      [radio1, radio2, radio3, radio4][i % 4].check
      progressbar.filled += 5
      if progressbar.filled == 100
        progressbar.filled = 0
      end

      if ch = textv[i]?
        textarea.emit Event::KeyPress.new ch
      else
        i = 0
      end

      new_letter = textboxv[i]?
      if new_letter
        textbox.value += new_letter
      else
        textbox.value = ""
      end
      i += 1
      Fiber.yield
      sleep 0.2
    end
  end

  sleep
end
