require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize
    s = Screen.new always_propagate: [::Tput::Key::Tab, ::Tput::Key::ShiftTab, ::Tput::Key::CtrlQ]

    note = Widget::Text.new content: "Use Tab/Shift+Tab to cycle between boxes, Ctrl+q to exit"

    i1 = Widget::Checkbox.new \
      name: "w1",
      width: 10,
      height: 3,
      top: 6,
      left: 6,
      content: "Box1",
      style: Style.new(fg: "yellow", bg: "red", border: true)

    i2 = Widget::Checkbox.new \
      name: "w2",
      width: 10,
      height: 3,
      top: 6,
      left: 18,
      content: "Box2",
      style: Style.new(fg: "yellow", bg: "red", border: true)

    i3 = Widget::Checkbox.new \
      name: "w3",
      width: 10,
      height: 3,
      top: 6,
      left: 30,
      content: "Box3",
      style: Style.new(fg: "yellow", bg: "red", border: true)

    s.append i1, i2, i3, note

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
