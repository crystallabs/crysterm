require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

# Port of Blessed's test/widget-listbar.js
#
# Demonstrates the interactive `Widget::CommandBar`: a horizontal bar of
# selectable commands with keyboard (and vi_keys) navigation, mouse clicks,
# per-command hotkeys, and `auto_command_keys` (number keys select tabs).
# Selecting a command updates the box in the top-right corner.
class X
  def initialize
    s = CT::Window.new always_propagated_keys: [::Tput::Key::Tab, ::Tput::Key::ShiftTab, ::Tput::Key::CtrlQ]

    # Blessed: borderless `width:'shrink', height:'shrink'` box pinned top-right.
    # `shrink_to_fit: true` is Crysterm's shrink.
    box = CW::Box.new \
      parent: s,
      top: 0,
      right: 0,
      shrink_to_fit: true,
      content: "..."

    bar = CW::CommandBar.new \
      bottom: 0,
      left: 3,
      right: 3,
      height: 3,
      mouse: true,
      keys: true,
      vi_keys: true,
      auto_command_keys: true,
      styles: CT::Styles.new(
        normal: CT::Style.new(
          bg: "green",
          border: true,
          item: CT::Style.new(bg: "red"),
        ),
        selected: CT::Style.new(bg: "blue"),
      )

    # Each command updates the corner box and re-renders.
    names = %w[one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen]
    names.each do |name|
      bar.add_item(name) do
        box.content = "Pressed #{name}."
        s.update
      end
    end

    s.append bar
    bar.focus

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
