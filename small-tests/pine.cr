require "../src/crysterm"

module Crysterm
  d = Display.new
  s = Screen.new display: d

  hbar = Widget::Pine::HeaderBar.new title_content: "ALPINE 2.20", section_content: "MAIN MENU", subsection_content: "Folder: INDEX", info_content: "37 Messages"

  cbar = Widget::Box.new left: "center", top: "100%-5", content: %q{For good information press "?"}

  sbar = Widget::Pine::StatusBar.new top: "100%-4"

  s.append hbar, sbar, cbar

  s.on(Crysterm::Event::KeyPress) do
    s.display.destroy
    exit
  end

  s.render

  sleep 2

  sbar.status.set_content "[Already at {underline}bottom{/underline} of list]"

  d.exec
end
