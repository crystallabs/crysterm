require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize
    s = Screen.new always_propagate: [::Tput::Key::CtrlQ]

    # parent: l,
    i = Widget::TextArea.new \
      width: 10,
      height: 8,
      top: 4,
      left: 8,
      content: "Kico\n2\n3", # "center", left: "center" #, border: true #, display: s
      style: Style.new(fg: "yellow", bg: "red", border: true),
      input_on_focus: true

    s.append i

    s.on(Crysterm::Event::KeyPress) do |e|
      if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
        s.destroy
        exit
      end
    end

    s.render

    s.display.exec
  end
end

X.new
