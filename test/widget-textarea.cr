require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize
    s = Screen.new ignore_locked: [::Tput::Key::CtrlQ]

    # parent: l,
    i = Widget::TextArea.new \
      width: "half",
      height: "half",
      top: "center",
      left: "center",
      parse_tags: true,
      style: Style.new(bg: "blue", scrollbar: Style.new(bg: "red"), track: Style.new(char: '▒')),
      track: true,
      input_on_focus: true,
      scrollbar: true

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
