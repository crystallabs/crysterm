require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

class X
  include EventHandler

  def initialize
    s = CT::Window.new always_propagated_keys: [::Tput::Key::CtrlQ]

    # parent: l,
    i = CW::PlainTextEdit.new \
      width: "50%",
      height: "50%",
      top: "center",
      left: "center",
      style: CT::Style.new(bg: "blue", scrollbar: CT::Style.new(bg: "red"), track: CT::Style.new(fill_char: '▒')),
      track: true,
      input_on_focus: true,
      scrollbar_policy: :as_needed

    s.append i

    s.on(CT::Event::KeyPress) do |e|
      if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
        s.destroy
        exit
      end
    end

    s.update

    s.exec
  end
end

X.new
