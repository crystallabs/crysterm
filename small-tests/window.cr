require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize
    w = Window.new

    # l = Widget::Layout.new width: "100%", height: "100%", border: true, style: Style.new( fg: "black", bg: "white" )
    # w.append l

    # parent: l,
    i = Widget::Box.new \
      width: 10,
      height: 10,
      top: 4,
      left: 8,
      content: "Heyo", # "center", left: "center" #, border: true #, screen: s
      border: true,
      style: Style.new(fg: "yellow", bg: "red")

    # parent: l,
    i2 = Widget::Box.new \
      width: 10,
      height: 10,
      top: 2,
      left: 20,
      content: "Heyo", # "center", left: "center" #, border: true #, screen: s
      border: true,
      style: Style.new(fg: "black", bg: "red")

    on(Crysterm::Event::KeyPress) do |e|
      if e.char == 'q'
        w.destroy
        exit
      end
    end

    w.render

    w.screen.exec
  end
end

X.new
