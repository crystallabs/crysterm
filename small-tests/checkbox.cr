require "../src/crysterm"

module Crysterm
  include Tput::Namespace
  include Widgets

  s = Screen.new ignore_locked: [Tput::Key::CtrlQ]

  c1 = Checkbox.new content: "Checkbox 1", left: 6, top: 0
  c2 = Checkbox.new content: "Checkbox 2", left: 6, top: 2
  c3 = Checkbox.new content: "Checkbox 3", left: 6, top: 4
  c4 = Checkbox.new content: "Checkbox 4", left: 6, top: 6

  s.append c1, c2, c3, c4

  s.enable_keys c1
  s.enable_keys c2
  s.enable_keys c3
  s.enable_keys c4

  s.on(Crysterm::Event::KeyPress) do |e|
    e.key.try do |k|
      case k
      when .tab?
        s.focus_next
      when .shift_tab?
        s.focus_prev
      when .ctrl_q?
        exit
      end
    end
  end

  s.display.exec
end
