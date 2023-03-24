require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize
    s = Screen.new padding: 10

    # l = Widget::Layout.new width: "100%", height: "100%", border: true, style: Style.new( fg: "black", bg: "white" )
    # s.append l

    # parent: l,
    i = Widget::Box.new \
      width: 10,
      height: 10,
      top: 0,
      left: 0,
      content: "Test", # "center", left: "center" #, border: true
      style: Style.new(fg: "yellow", bg: "red", border: true)

    # parent: l,
    i2 = Widget::Box.new \
      width: 10,
      height: 10,
      top: 0,
      left: 20,
      content: "Test", # "center", left: "center" #, border: true
      style: Style.new(fg: "black", bg: "red", border: true)

    s.append i
    s.append i2

    s.on(Crysterm::Event::KeyPress) do |e|
      if e.char == 'q' || e.key = ::Tput::Key::CtrlQ
        s.destroy
        exit
      end
    end

    s.render

    s.exec
  end
end

X.new
