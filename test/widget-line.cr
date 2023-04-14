require "../src/crysterm"

module Crysterm
  include Tput::Namespace
  include Widgets

  s = Screen.new always_propagate: [Tput::Key::CtrlQ]

  c1 = Line.new left: 10, top: 4, orientation: :horizontal
  c2 = Line.new left: 10, size: 5, orientation: :vertical

  c3 = Line.new left: 20, top: 9, orientation: :horizontal, size: "90%"
  c4 = Line.new left: 20, size: 10, orientation: :vertical

  c5 = HLine.new left: 30, top: 14, size: "80%"
  c6 = VLine.new left: 30, size: 15

  c7 = HLine.new left: 40, top: 19, size: "70%"
  c8 = VLine.new left: 40, size: 20

  s.append c1, c2, c3, c4, c5, c6, c7, c8

  s.on(Crysterm::Event::KeyPress) do |e|
    e.key.try do |k|
      case k
      when .ctrl_q?
        s.destroy
        exit
      end
    end
  end

  s.exec
end
