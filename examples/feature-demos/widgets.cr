# FEATURE: rich widget library (30+ widgets).
#
# A compact showcase of several built-in widgets working together: a list, a
# progress bar, checkboxes, a button, a text box and a loading spinner — all
# animating at once.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Widgets"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}A few of Crysterm's 30+ widgets{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#303050")

list = Widget::List.new \
  parent: s, top: 1, left: 0, width: 22, height: 14,
  items: ["Box", "Button", "Checkbox", "RadioButton", "List", "Table",
          "ProgressBar", "TextArea", "Loading", "BigText", "Image", "Menu"],
  style: Style.new(fg: "white", bg: "black", border: true)

progress = Widget::ProgressBar.new \
  parent: s, top: 1, left: 23, width: 32, height: 3,
  content: "{center}Download{/center}", parse_tags: true, filled: 0,
  style: Style.new(fg: "green", bg: "#303030", border: true)

cb1 = Widget::Checkbox.new parent: s, top: 5, left: 24, content: "Enable feature A"
cb2 = Widget::Checkbox.new parent: s, top: 6, left: 24, content: "Enable feature B"
cb3 = Widget::Checkbox.new parent: s, top: 7, left: 24, content: "Enable feature C"

button = Widget::Button.new \
  parent: s, top: 9, left: 23, width: 32, height: 3, align: :hcenter,
  content: "OK", style: Style.new(fg: "yellow", bg: "blue", border: true)

input = Widget::TextBox.new \
  parent: s, top: 12, left: 23, width: 32, height: 1,
  style: Style.new(fg: "black", bg: "green")

spinner = Widget::Loading.new \
  parent: s, top: 1, left: 56, width: 22, height: 5,
  content: "Working", style: Style.new(fg: "cyan", border: true)
spinner.start

bigtext = Widget::BigText.new \
  parent: s, top: 6, left: 56, width: 22, height: 8,
  content: "OK", style: Style.new(fg: "magenta", border: true)

typed = "release-1.0.tar.gz"
i = 0
s.every(0.12.seconds) do
  progress.filled += 4
  progress.filled = 0 if progress.filled > 100
  cb1.toggle if i % 7 == 0
  cb2.toggle if i % 11 == 0
  cb3.toggle if i % 5 == 0
  list.down if i % 4 == 0
  input.value = typed[0, (i % (typed.size + 1))]
  i += 1
end

s.exec
