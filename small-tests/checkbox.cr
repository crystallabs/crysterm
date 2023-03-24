require "../src/crysterm"

module Crysterm
  include Tput::Namespace
  include Widgets

  s = Screen.new always_propagate: [Tput::Key::CtrlQ]
  s.cursor.shape = CursorShape::None
  s.cursor.artificial = true
  s.cursor.style.bg = "#0000ff"
  s.cursor.style.fg = "#00ff00"
  s.cursor.style.char = 'X'
  # s.cursor._hidden = true

  st = Styles.new(
    normal: Style.new(bg: "blue"),
    focused: Style.new(bg: "red")
  )

  c1 = Checkbox.new content: "Checkbox 1", left: 6, top: 0, styles: st
  c2 = Checkbox.new content: "Checkbox 2", left: 6, top: 2, styles: st
  c3 = Checkbox.new content: "Checkbox 3", left: 6, top: 4, styles: st
  c4 = Checkbox.new content: "Checkbox 4", left: 6, top: 6, styles: st
  label = Text.new content: "Cycle between widgets with Tab, Shift+Tab. Space to toggle, ctrl+q to quit.", top: 10

  s.append c1, c2, c3, c4, label

  s.on(Crysterm::Event::KeyPress) do |e|
    e.key.try do |k|
      case k
      when .tab?
        s.focus_next
      when .shift_tab?
        s.focus_previous
      when .ctrl_q?
        exit
      end
      s.render
    end
  end

  s.exec
end
