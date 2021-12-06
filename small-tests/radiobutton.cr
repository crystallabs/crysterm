require "../src/crysterm"

module Crysterm
  include Tput::Namespace

  s = Screen.new

  se = Widget::RadioSet.new

  b = Widget::RadioButton.new top: 2, left: 2, width: nil, height: nil,
    parent: se,
    resizable: true, content: "RB1",
    border: Border.new(type: BorderType::Line),
    style: Style.new(fg: "yellow", bg: "magenta", border: Style.new(fg: "#ffffff"))

  b2 = Widget::RadioButton.new top: 2, left: 12, width: nil, height: nil,
    parent: se,
    resizable: true, content: "RB2",
    border: Border.new(type: BorderType::Line),
    style: Style.new(fg: "yellow", bg: "magenta", border: Style.new(fg: "#ffffff"))

  b3 = Widget::RadioButton.new top: 2, left: 22, width: nil, height: nil,
    parent: se,
    resizable: true, content: "RB3",
    border: Border.new(type: BorderType::Line),
    style: Style.new(fg: "yellow", bg: "magenta", border: Style.new(fg: "#ffffff"))

  s.append se
  s.append b
  s.append b2
  s.append b3

  b.focus

  s.render

  s.on(Event::KeyPress) do |e|
    if e.char == 'q'
      exit
    elsif e.key == ::Tput::Key::CtrlQ
      exit
    elsif e.key == ::Tput::Key::Tab
      s.focus_next
    elsif e.key == ::Tput::Key::ShiftTab
      s.focus_previous
    end
  end

  sleep
end
