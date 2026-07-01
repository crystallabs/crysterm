require "../../src/crysterm"

# Port of Blessed's test/widget-listbar.js
#
# Demonstrates the interactive `Widget::ListBar`: a horizontal bar of
# selectable commands with keyboard (and vi) navigation, mouse clicks,
# per-command hotkeys, and `auto_command_keys` (number keys select tabs).
# Selecting a command updates the box in the top-right corner.
class X
  include Crysterm

  def initialize
    s = Window.new always_propagate: [::Tput::Key::Tab, ::Tput::Key::ShiftTab, ::Tput::Key::CtrlQ]

    # Blessed: borderless `width:'shrink', height:'shrink'` box pinned top-right.
    # `resizable: true` is Crysterm's shrink.
    box = Widget::Box.new \
      parent: s,
      top: 0,
      right: 0,
      resizable: true,
      content: "..."

    bar = Widget::ListBar.new \
      bottom: 0,
      left: 3,
      right: 3,
      height: 3,
      mouse: true,
      keys: true,
      vi: true,
      auto_command_keys: true,
      styles: Styles.new(
        normal: Style.new(
          bg: "green",
          border: true,
          item: Style.new(bg: "red"),
        ),
        selected: Style.new(bg: "blue"),
      )

    # Each command updates the corner box and re-renders.
    names = %w[one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen]
    names.each do |name|
      bar.add(name) do
        box.set_content "Pressed #{name}."
        s.render
      end
    end

    s.append bar
    bar.focus

    s.on(Crysterm::Event::KeyPress) do |e|
      if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
        s.destroy
        exit
      end
    end

    s.render

    s.exec
  end
end

X.new
