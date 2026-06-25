require "../../src/crysterm"

# Port of Blessed's test/widget-file.js
#
# Demonstrates `Widget::FileManager`: browse the filesystem with the keyboard
# (Enter to descend into a directory or select a file, `..` to go up). The
# label shows the current path. Press `p` to `#pick` a file: the manager hides,
# reappears, and on selection shows the chosen path in a box.
class X
  include Crysterm

  def initialize
    s = Screen.new always_propagate: [::Tput::Key::CtrlQ], full_unicode: true

    fm = Widget::FileManager.new \
      parent: s,
      keys: true,
      vi: true,
      label: " %path ",
      cwd: ENV["HOME"]? || Dir.current,
      height: "half",
      width: "half",
      top: "center",
      left: "center",
      scrollbar: true,
      style: Style.new(border: true)

    box = Widget::Box.new \
      parent: s,
      height: "half",
      width: "half",
      top: "center",
      left: "center",
      style: Style.new(bg: "green", border: true)
    box.hide

    fm.on(Crysterm::Event::ChangeDir) do |e|
      fm.set_label " #{e.path} "
      s.render
    end

    fm.on(Crysterm::Event::OpenFile) do |e|
      box.set_content "Selected: #{e.path}"
      box.show
      s.render
      spawn do
        sleep 2.seconds
        box.hide
        s.render
      end
    end

    fm.refresh
    fm.focus
    s.render

    s.on(Crysterm::Event::KeyPress) do |e|
      case
      when e.char == 'q' || e.key == ::Tput::Key::CtrlQ
        s.destroy
        exit
      when e.char == 'p'
        fm.pick do |file|
          box.set_content file ? "Picked: #{file}" : "Cancelled"
          box.show
          s.render
          spawn do
            sleep 2.seconds
            box.hide
            s.render
          end
        end
      end
    end

    s.exec
  end
end

X.new
