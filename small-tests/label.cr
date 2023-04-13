require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize
    s = Screen.new always_propagate: [::Tput::Key::Tab, ::Tput::Key::ShiftTab, ::Tput::Key::CtrlQ]

    label = Widget::Label.new content: "This is a label.", style: Style.new border: true

    s.append label

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

    s.exec
  end
end

X.new
