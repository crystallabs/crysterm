require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize
    s = Screen.new ignore_locked: [::Tput::Key::Tab, ::Tput::Key::ShiftTab, ::Tput::Key::CtrlQ]

    #note = Widget::TextBox.new content: "Use Tab/Shift+Tab to cycle between boxes, Ctrl+q to exit"

    i1 = Widget::Checkbox.new \
      name: "w1",
      width: 10,
      height: 3,
      top: 6,
      left: 6,
      content: "Box1",
      border: true,
      style: Style.new(fg: "yellow", bg: "red")

    i2 = Widget::Checkbox.new \
      name: "w2",
      width: 10,
      height: 3,
      top: 6,
      left: 18,
      content: "Box2",
      border: true,
      style: Style.new(fg: "yellow", bg: "red")

    i3 = Widget::Checkbox.new \
      name: "w3",
      width: 10,
      height: 3,
      top: 6,
      left: 30,
      content: "Box3",
      border: true,
      style: Style.new(fg: "yellow", bg: "red")

    s.append i1, i2, i3

    s.on(Crysterm::Event::KeyPress) do |e|
      if e.key == ::Tput::Key::CtrlQ
        s.destroy
        exit
      elsif e.key == ::Tput::Key::Tab
        s.focus_next
      elsif e.key == ::Tput::Key::ShiftTab
        s.focus_previous
      end
      s.render
    end

    s.display.exec
  end
end

X.new
