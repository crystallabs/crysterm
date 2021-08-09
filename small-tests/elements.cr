require "../src/crysterm"

# This is a basic example from which widget.png is produced
# (See misc/widget.*)

class X
  include Crysterm
  include EventHandler

  def initialize
    s = Screen.new

    b = Widget::Box.new \
      width: 160,
      height: 40,
      top: 0,
      left: 0,
      style: Style.new(bg: "#ff5600")

    i = Widget::Button.new \
      width: 40,
      height: 11,
      top: 4,
      left: 28,
      padding: 4,
      label: "Frame text ",
      content: "Press Enter or Space to exit",
      align: ::Tput::AlignFlag::Center,
      border: true,
      style: Style.new(fg: "yellow", bg: "blue", transparency: 0.9),
      shadow: true

    s.append b
    s.append i

    s.focus i

    i.on(::Crysterm::Event::Press) do
      STDERR.puts "Pressed; exiting in 2 seconds"
      sleep 2
      exit
    end

    s.on(::Crysterm::Event::KeyPress) do |e|
      if e.char == 'q' || e.key.try(&.==(::Tput::Key::CtrlQ))
        s.destroy
      end
    end

    s.display.exec
  end
end

X.new
