require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize
    s = Screen.new always_propagate: [::Tput::Key::CtrlQ]

    # parent: l,
    i = Widget::List.new \
      name: "list",
      width: "half",
      height: "half",
      top: "center",
      left: "center",
      parse_tags: true,
      style: Style.new(bg: "blue", scrollbar: Style.new(bg: "red"), track: Style.new(char: '▒'), selected: Style.new(fg: "yellow", alpha: true), padding: 1),
      track: true,
      scrollbar: true

    i.set_items ["{left}one{/}", "{center}two{/}", "{right}three{/}"]

    s.append i

    s.on(Crysterm::Event::KeyPress) do |e|
      if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
        s.destroy
        exit
      end
    end

    s.exec
  end
end

X.new
