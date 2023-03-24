require "../src/crysterm"

module Crysterm
  include Tput::Namespace
  include Widgets

  s = Screen.new always_propagate: [Tput::Key::CtrlQ], title: "Crysterm Tech Demo"
  b = layout = Layout.new(
    parent: s,
    top: 0,
    left: 0,
    width: "100%",
    height: "100%",
    layout: LayoutType::Grid,
    overflow: Overflow::Ignore,
  )

  # b.focus

  box = Box.new(
    parent: layout,
    width: 36,
    height: 18,
    style: Style.new(border: BorderType::Line),
    content: "Plain box with some content."
  )

  button = Button.new(
    parent: layout,
    width: 36,
    height: 3,
    align: AlignFlag::HCenter,
    content: "Click me, I am a button.",
    style: Style.new(
      bg: "blue",
      fg: "yellow",
      border: Border.new(
        type: BorderType::Line,
        bg: "blue"
      ),
      shadow: true
    )
  )

  checkboxes = Box.new(
    parent: layout,
    width: 18,
    height: 18
  )
  checkbox1 = Checkbox.new parent: checkboxes, content: "Checkbox 1", top: 0
  checkbox2 = Checkbox.new parent: checkboxes, content: "Checkbox 2", top: 2
  checkbox3 = Checkbox.new parent: checkboxes, content: "Checkbox 3", top: 4
  checkbox4 = Checkbox.new parent: checkboxes, content: "Checkbox 4", top: 6

  radioset = RadioSet.new parent: layout, width: 20, height: 18
  radio1 = RadioButton.new parent: radioset, content: "Radio button 1", top: 0
  radio2 = RadioButton.new parent: radioset, content: "Radio button 2", top: 2
  radio3 = RadioButton.new parent: radioset, content: "Radio button 3", top: 4
  radio4 = RadioButton.new parent: radioset, content: "Radio button 4", top: 6

  progressbar = ProgressBar.new \
    parent: layout,
    content: "{center}Progress bar{/center}",
    parse_tags: true,
    filled: 50,
    width: 36,
    height: 3,
    style: Style.new(
      fg: "yellow",
      bg: "magenta",
      border: Border.new(
        fg: "#ffffff"
      ),
      shadow: true,
    )

  loading = Loading.new \
    parent: layout,
    align: AlignFlag::HCenter,
    width: 36,
    height: 18,
    icons: ["Preparing", "Loading", "Processing", "Saving", "Analyzing"],
    content: "Please wait...",
    style: Style.new(alpha: true, fg: "white", bg: "black", border: Border.new(fg: "white", bg: "black"))

  question = Question.new \
    parent: layout,
    content: "Question: {bold}HOT{/bold} or NOT?",
    # hidden: false,
    parse_tags: true,
    width: 36,
    height: 9,
    style: Style.new(
      alpha: true,
      fg: "yellow",
      bg: "magenta",
      border: Border.new(
        fg: "#ffffff"
      ),
      shadow: true,
    )
  question.ask { }

  # overlayimage = OverlayImage.new \
  #  parent: layout,
  #  width: 36,
  #  height: 18,
  #  style: Style.new(
  #    fg: "yellow",
  #    bg: "magenta",
  #    border: Border.new(
  #      fg: "#ffffff"
  #    ),
  #    shadow: false,
  #  )

  bigtext = BigText.new(
    parent: layout,
    width: 36,
    height: 18,
    style: Style.new(border: true),
    content: "Big"
  )

  textarea = TextArea.new(
    parent: layout,
    width: 36,
    input_on_focus: true,
    height: 18,
    style: Style.new(border: true),
    content: ""
  )

  textbox = TextBox.new(
    parent: layout,
    width: 36,
    height: 3,
    style: Style.new(border: true),
    content: "TextBox. One-line element."
  )

  boxtp2 = Box.new(
    parent: s,
    width: 60,
    height: 16,
    top: 18,
    left: 160,
    content: "Hello, World! See translucency and shadow.",
    style: Style.new(bg: "#870087", border: BorderType::Bg, shadow: Shadow.new(true, true, false, false))
  )
  boxtp1 = Box.new(
    parent: s,
    top: 14,
    left: 150,
    width: 60,
    height: 14,
    content: "See indeed.",
    style: Style.new(bg: "#729fcf", alpha: true, border: true, shadow: true)
  )

  loading2 = Loading.new \
    parent: layout,
    align: AlignFlag::Right,
    compact: true,
    interval: 0.2.seconds,
    width: 36,
    height: 3,
    content: "In progress!...",
    style: Style.new(border: true)

  s.on(Event::KeyPress) do |e|
    # e.accept
    if e.key == ::Tput::Key::CtrlQ || e.char == 'q'
      s.destroy
      exit
    end
  end

  s.render

  textv = "TextArea. This is a multi-line user input enabled widget with automatic content wrapping. " +
          "There is a lot of text that can fit it, when the terminal doesn't use too big font."
  textboxv = " This will add more text to textbox and always show only visible portion."

  textarea.focus
  loading.start
  loading2.start
  i = 0
  spawn do
    loop do
      [checkbox1, checkbox2, checkbox3, checkbox4][i % 4].toggle
      [radio1, radio2, radio3, radio4][i % 4].check
      progressbar.filled += 5
      if progressbar.filled > 100
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

  s.render

  s.exec
end
