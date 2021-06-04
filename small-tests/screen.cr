require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize
    s = Screen.new

    # l = Widget::Layout.new width: "100%", height: "100%", border: true, style: Style.new( fg: "black", bg: "white" )
    # s.append l

    # parent: l,
    i = Widget::Box.new \
      width: 10,
      height: 10,
      top: 4,
      left: 8,
      content: "Test", # "center", left: "center" #, border: true #, display: s
      border: true,
      style: Style.new(fg: "yellow", bg: "red")

    # parent: l,
    i2 = Widget::Box.new \
      width: 10,
      height: 10,
      top: 2,
      left: 20,
      content: "Test", # "center", left: "center" #, border: true #, display: s
      border: true,
      style: Style.new(fg: "black", bg: "red")

    s.append i
    s.append i2

    s.on(Crysterm::Event::KeyPress) do |e|
      if e.char == 'q' || e.key = ::Tput::Key::CtrlQ
        s.destroy
        exit
      end
    end

    s.render

    s.display.exec
  end
end

X.new
