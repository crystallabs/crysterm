require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

# Port of Blessed's test/widget-table.js
#
# Demonstrates the static `Widget::Table`: aligned columns, styled line
# borders/header/cell, tag-colored cells, CJK characters, and re-setting data after a delay.
class X
  DU   = "杜"
  JUAN = "鹃"

  def initialize
    s = CT::Window.new always_propagated_keys: [::Tput::Key::CtrlQ], full_unicode: true

    table = CW::Table.new \
      top: "center",
      left: "center",
      parse_tags: true,
      align: ::Tput::AlignFlag::Center,
      style: CT::Style.new(
        border: CT::Border.new(fg: "red"),
        header: CT::Style.new(fg: "blue", bold: true),
        cell: CT::Style.new(fg: "magenta"),
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

    table.rows = data2
    s.append table
    s.update

    spawn do
      sleep 3.seconds
      table.rows = data1
      s.update
    end

    s.on(CT::Event::KeyPress) do |e|
      if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
        s.destroy
        exit
      end
    end

    s.exec
  end
end

X.new
