require "../../src/crysterm"

# Port of Blessed's test/widget-table.js
#
# Demonstrates the static `Widget::Table`: aligned columns, line borders with
# styled header/cell/border, tag-colored cells, wide (CJK) characters, and
# re-setting the data after a delay.
class X
  include Crysterm

  DU   = "杜"
  JUAN = "鹃"

  def initialize
    s = Screen.new always_propagate: [::Tput::Key::CtrlQ], full_unicode: true

    table = Widget::Table.new \
      top: "center",
      left: "center",
      parse_tags: true,
      align: ::Tput::AlignFlag::Center,
      style: Style.new(
        border: Border.new(fg: "red"),
        header: Style.new(fg: "blue", bold: true),
        cell: Style.new(fg: "magenta"),
      )

    data1 = [
      ["Animals", "Foods", "Times"],
      ["{red-fg}Elephant{/red-fg}", "Apple", "1:00am"],
      ["Bird (#{DU}#{JUAN})", "Orange", "2:15pm"],
      ["T-Rex", "Taco", "8:45am"],
      ["Mouse", "Cheese", "9:05am"],
    ]

    data2 = [
      ["Animals", "Foods", "Times", "Numbers"],
      ["{red-fg}Elephant{/red-fg}", "Apple", "1:00am", "One"],
      ["Bird (#{DU}#{JUAN})", "Orange", "2:15pm", "Two"],
      ["T-Rex", "Taco", "8:45am", "Three"],
      ["Mouse", "Cheese", "9:05am", "Four"],
    ]

    table.set_data data2
    s.append table
    s.render

    spawn do
      sleep 3.seconds
      table.set_data data1
      s.render
    end

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
