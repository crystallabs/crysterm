require "./spec_helper"

include Crysterm

private def ips_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `Mixin::Interactive`'s vi page-scroll keys (Ctrl-U/D/B/F) used to be gated on
# `height.is_a? Int`, so a scrollable widget with a percentage height (`"100%"`)
# or no explicit height dropped every page-scroll key (line scrolling still
# worked). The handler now sizes the page step off the resolved `aheight`.
describe "Mixin::Interactive page scroll with non-Int height" do
  it "pages down with Ctrl-D when height is a percentage" do
    s = ips_screen
    input = Crysterm::Widget::Input.new(
      parent: s,
      width: "100%",
      height: "100%",
      scrollable: true,
      keys: true,
      vi: true,
      content: (1..60).map { |i| "line #{i}" }.join('\n'))
    s._render

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
    s = ips_screen
    input = Crysterm::Widget::Input.new(
      parent: s,
      width: "100%",
      height: "100%",
      scrollable: true,
      keys: true,
      vi: true,
      content: (1..60).map { |i| "line #{i}" }.join('\n'))
    s._render

    # Jump well down first, then page back up.
    input.scroll_to 40
    down = input.scroll_position
    down.should be > 0

    input.emit Crysterm::Event::KeyPress, '\0', Tput::Key::CtrlU
    input.scroll_position.should be < down
  end
end
