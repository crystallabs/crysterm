# Example: Crysterm::Layout::Masonry
#
# Minimal, self-contained example of a single Masonry.
# Run it:     crystal run tests/layout/masonry/masonry.cr
require "../../widget/example"

alias CT = Crysterm
alias CW = CT::Widgets

CT::WidgetExample.run "Masonry" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = CW::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: CT::Layout::Masonry.new
  # Varying heights flow into the shortest column — the masonry effect.
  [4, 6, 3, 5, 7, 4, 5, 3].each_with_index do |h, i|
    CW::Box.new parent: container, width: 16, height: h,
      content: "{center}##{i + 1}{/center}", parse_tags: true
  end
end
