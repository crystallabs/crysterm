require "../src/crysterm"

module Crysterm
  include Tput::Namespace
  include Widgets

  s = Screen.new always_propagate: [Tput::Key::CtrlQ], title: "Crysterm Tech Demo"

  boxtp2 = Box.new(
    # parent: s,
    width: 60,
    height: 20,
    top: 4,
    left: 4,
    content: "Hello, World! See translucency and shadow.",
    style: Style.new("bg": "#870087", border: BorderType::Bg, shadow: true)
  )
  boxtp1 = Box.new(
    # parent: s,
    top: 10,
    left: 10,
    width: 35,
    height: 8,
    content: "See indeed.",
    style: Style.new("bg": "#729fcf", alpha: true, border: true, shadow: Shadow.new(false, true, false, true))
  )
  boxtp0 = Box.new(
    # parent: s,
    top: 15,
    left: 15,
    width: 20,
    height: 8,
    content: "See indeed.",
    style: Style.new("bg": "#729fcf", alpha: true, border: true, shadow: Shadow.new(true, true, true, true))
  )
  boxtpm1 = Box.new(
    # parent: s,
    top: 7,
    left: 30,
    width: 20,
    height: 8,
    content: "See indeed.",
    style: Style.new("bg": "#729fcf", alpha: true, border: true, shadow: true)
  )
  s.append boxtp2
  s.append boxtp1
  s.append boxtpm1

  s.on(Event::KeyPress) do |e|
    # e.accept!
    if e.key == ::Tput::Key::CtrlQ || e.char == 'q'
      s.display.destroy
      exit
    end
  end

  s.display.exec
end
