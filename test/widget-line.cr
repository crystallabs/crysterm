require "../src/crysterm"

module Crysterm
  include Tput::Namespace
  include Widgets

  s = Screen.new always_propagate: [Tput::Key::CtrlQ]

  c1 = Line.new left: 6, top: 4, height: 1, width: 10, orientation: ::Tput::Orientation::Horizontal
  c2 = Line.new left: 6, top: 6, height: 10, width: 1, orientation: ::Tput::Orientation::Vertical

  s.append c1, c2

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
