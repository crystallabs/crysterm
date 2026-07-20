require "../../src/crysterm"

# Port of Blessed's test/widget-listtable.js
#
# Demonstrates `Widget::ListTable`: selectable table with pinned header row,
# line borders, styled header/cell, keyboard/vi_keys navigation, and re-setting data after a delay.
class X
  include Crysterm
  include Crysterm::Widgets

  DU   = "杜"
  JUAN = "鹃"

  def initialize
    s = Window.new always_propagated_keys: [::Tput::Key::CtrlQ], full_unicode: true

    table = ListTable.new \
      top: "center",
      left: "center",
      height: "70%",
      keys: true,
      vi_keys: true,
      parse_tags: true,
      align: ::Tput::AlignFlag::Center,
      styles: Styles.new(
        normal: Style.new(
          border: Border.new(fg: "red"),
          header: Style.new(fg: "blue", bold: true),
          cell: Style.new(fg: "magenta"),
        ),
        selected: Style.new(bg: "blue"),
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
    table.focus
    s.render

    spawn do
      sleep 3.seconds
      table.rows = data1
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
