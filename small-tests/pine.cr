require "../src/crysterm"

module Crysterm
  d = Display.new
  s = Screen.new display: d

  hb = Widget::Pine::HeaderBar.new title_content: "ALPINE 2.20", section_content: "MAIN MENU", subsection_content: "Folder: INDEX", info_content: "37 Messages"

  sb = Widget::Pine::StatusBar.new top: "100%-4"

  s.append hb, sb

  s.on(Crysterm::Event::KeyPress) do
    s.display.destroy
    exit
  end

  s.render

  sleep 2

  sb.status.set_content "[Already at bottom of list]"

  d.exec
end
