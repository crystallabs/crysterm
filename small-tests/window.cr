require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize

    a = App.new

    s = Screen.new app: a

    #l = Widget::Layout.new width: "100%", height: "100%", border: true, style: Style.new( fg: "black", bg: "white" )
    #s.append l

      #parent: l,
    i = Widget::Box.new \
      width: 10,
      height: 10,
      top: 4,
      left: 8,
      content: "Heyo", #"center", left: "center" #, border: true #, screen: s
      border: true,
      style: Style.new( fg: "yellow", bg: "red" )

      #parent: l,
    i2 = Widget::Box.new \
      width: 10,
      height: 10,
      top: 2,
      left: 20,
      content: "Heyo", #"center", left: "center" #, border: true #, screen: s
      border: true,
      style: Style.new( fg: "black", bg: "red" )

    on(Crysterm::Event::KeyPress) do |e|
      if e.char == 'q'
        s.destroy
        exit
      end
    end

    s.render

    a.exec
  end

end

X.new
