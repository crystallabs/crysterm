require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize
    s = Screen.new

    i = Widget::Button.new \
      width: 50,
      height: 5,
      top: 4,
      left: 8,
      content: "Press q or Ctrl+q to exit",
      align: ::Tput::AlignFlag::Center,
      style: Style.new(fg: "yellow", bg: "blue", border: true)

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
        exit
      end
    end

    s.exec
  end
end

X.new
