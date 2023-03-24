require "../src/crysterm"

module Crysterm
  include Tput::Namespace

  s = Screen.new

  se = Widget::RadioSet.new

  st = Styles.new(
    normal: Style.new(fg: "yellow", bg: "magenta", border: Border.new(fg: "#ffffff")),
    focused: Style.new(fg: "yellow", bg: "magenta", border: Border.new(fg: "#ff0000")),
  )

  b = Widget::RadioButton.new top: 2, left: 2, width: nil, height: nil,
    parent: se,
    resizable: true, content: "RB1",
    styles: st

  b2 = Widget::RadioButton.new top: 2, left: 12, width: nil, height: nil,
    parent: se,
    resizable: true, content: "RB2",
    styles: st

  b3 = Widget::RadioButton.new top: 2, left: 22, width: nil, height: nil,
    parent: se,
    resizable: true, content: "RB3",
    styles: st

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
    s.render
  end

  s.exec

  sleep
end
