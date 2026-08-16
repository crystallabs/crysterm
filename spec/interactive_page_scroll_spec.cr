require "./spec_helper"

include Crysterm

# `Mixin::Interactive`'s vi_keys page-scroll keys (Ctrl-U/D/B/F) must work for a
# scrollable widget with a percentage height (`"100%"`) or no explicit height:
# the handler sizes the page step off the resolved `aheight`, not a
# `height.is_a? Int` gate that would drop every page-scroll key.
describe "Mixin::Interactive page scroll with non-Int height" do
  it "pages down with Ctrl-D when height is a percentage" do
    s = headless_screen(80, 24)
    input = Crysterm::Widget::AbstractInteractive.new(
      parent: s,
      width: "100%",
      height: "100%",
      scrollable: true,
      keys: true,
      vi_keys: true,
      content: (1..60).map { |i| "line #{i}" }.join('\n'))
    s.repaint

    input.scroll_position.should eq 0
    # Half-page down: ~aheight/2 ≈ 12 lines on a 24-row screen. `scroll_position` is
    # the combined `child_base + child_offset`; assert on the combined value.
    input.emit Crysterm::Event::KeyPress, '\0', Tput::Key::CtrlD
    input.scroll_position.should be > 0
    paged = input.scroll_position

    # Full page down moves strictly further than the half page did.
    input.emit Crysterm::Event::KeyPress, '\0', Tput::Key::CtrlF
    input.scroll_position.should be > paged
  end

  it "pages back up with Ctrl-U / Ctrl-B" do
    s = headless_screen(80, 24)
    input = Crysterm::Widget::AbstractInteractive.new(
      parent: s,
      width: "100%",
      height: "100%",
      scrollable: true,
      keys: true,
      vi_keys: true,
      content: (1..60).map { |i| "line #{i}" }.join('\n'))
    s.repaint

    # Jump well down first, then page back up.
    input.scroll_to 40
    down = input.scroll_position
    down.should be > 0

    input.emit Crysterm::Event::KeyPress, '\0', Tput::Key::CtrlU
    input.scroll_position.should be < down
  end
end
