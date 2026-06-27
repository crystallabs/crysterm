require "./spec_helper"

include Crysterm

private def ips_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `Mixin::Interactive`'s vi page-scroll keys (Ctrl-U/D/B/F) used to be gated on
# `height.is_a? Int`, so a scrollable widget sized with a *percentage* height
# (`"100%"` — the usual case for a full-pane scroller) or no explicit height at
# all dropped every page-scroll key: line scrolling (Up/Down) worked but
# half-/full-page paging did nothing. The handler now sizes the page step off
# the resolved `aheight`, so paging works regardless of how the height was
# specified.
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

    input.get_scroll.should eq 0
    # Half-page down: ~aheight/2 ≈ 12 lines on a 24-row screen. (`get_scroll`
    # is the combined `child_base + child_offset` position; a half page on a
    # tall viewport lands in `child_offset`, so assert on the combined value.)
    input.emit Crysterm::Event::KeyPress, '\0', Tput::Key::CtrlD
    input.get_scroll.should be > 0
    paged = input.get_scroll

    # Full page down moves strictly further than the half page did.
    input.emit Crysterm::Event::KeyPress, '\0', Tput::Key::CtrlF
    input.get_scroll.should be > paged
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
    down = input.get_scroll
    down.should be > 0

    input.emit Crysterm::Event::KeyPress, '\0', Tput::Key::CtrlU
    input.get_scroll.should be < down
  end
end
