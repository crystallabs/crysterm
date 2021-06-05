require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize
    s = Screen.new ignore_locked: [::Tput::Key::Tab, ::Tput::Key::ShiftTab, ::Tput::Key::CtrlQ]

    i1 = Widget::TextBox.new \
      width: 10,
      height: 3,
      top: 6,
      left: 6,
      content: "Box1",
      border: true,
      style: Style.new(fg: "yellow", bg: "red")

    i2 = Widget::Layout.new width: "100%", height: "100%"
    i3 = Widget::Layout.new width: "100%", height: "100%"

    i2.append i1
    i3.append i1

    STDERR.puts i1.parent.hash,
      i2.children.size,
      i3.children.size
  end
end

X.new
