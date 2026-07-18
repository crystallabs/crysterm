require "./spec_helper"

include Crysterm

# `Mixin::NavKeys` single-sources the vertical navigation key-map shared by
# `Mixin::Interactive` (viewport scrolling) and `Mixin::ItemView` (selection
# movement): the *same* physical keys mean "one back / one forward / half page /
# full page / first / last" in both, only the action differs.
#
# The Interactive side is pinned by `bugs6_mixin_util_spec.cr`
# (PageUp/Down, Home/End, Ctrl-U/D/B/F, vi j/k/g/G). This spec pins the
# ItemView side against the *same* table, so an accidental divergence in either
# family fails.

private def nk_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 40,
    height: 10,
    default_quit_keys: false)
end

# A List tall enough that a page step differs from a single step.
private def nk_list(vi = false)
  s = nk_screen
  list = Crysterm::Widget::List.new(
    parent: s, vi: vi,
    top: 0, left: 0, width: 20, height: 6,
    items: (1..30).map { |i| "item #{i}" })
  s.render
  {s, list}
end

private def nk_press(w, ch : Char = '\0', key : Tput::Key? = nil)
  w.emit Crysterm::Event::KeyPress.new(ch, key)
end

describe Crysterm::Mixin::NavKeys do
  describe "ItemView selection maps the shared nav key-map" do
    it "Down / Up move the selection one item" do
      _, list = nk_list
      list.current_index.should eq 0
      nk_press list, key: Tput::Key::Down
      list.current_index.should eq 1
      nk_press list, key: Tput::Key::Up
      list.current_index.should eq 0
    end

    it "Home / End jump to the first / last item" do
      _, list = nk_list
      nk_press list, key: Tput::Key::End
      list.current_index.should eq 29
      nk_press list, key: Tput::Key::Home
      list.current_index.should eq 0
    end

    it "PageDown / PageUp move by a page (further than one item)" do
      _, list = nk_list
      nk_press list, key: Tput::Key::PageDown
      paged = list.current_index
      paged.should be > 1
      nk_press list, key: Tput::Key::PageUp
      list.current_index.should be < paged
    end

    it "Ctrl-D / Ctrl-U move by a half page (bounded by the full page)" do
      _, list = nk_list
      nk_press list, key: Tput::Key::CtrlD
      half = list.current_index
      half.should be > 0
      nk_press list, key: Tput::Key::Home
      nk_press list, key: Tput::Key::PageDown
      list.current_index.should be >= half
    end

    it "binds vi j/k and g/G only when vi is enabled" do
      _, off = nk_list vi: false
      nk_press off, ch: 'j'
      off.current_index.should eq 0 # inert without vi

      _, on = nk_list vi: true
      nk_press on, ch: 'j'
      on.current_index.should eq 1
      nk_press on, ch: 'k'
      on.current_index.should eq 0
      nk_press on, ch: 'G'
      on.current_index.should eq 29
      nk_press on, ch: 'g'
      on.current_index.should eq 0
    end
  end

  describe "#nav_intent classification" do
    it "classifies the physical keys and leaves others as None" do
      _, list = nk_list vi: true
      mk = ->(ch : Char, key : Tput::Key?) { Crysterm::Event::KeyPress.new(ch, key) }
      list.nav_intent(mk.call('\0', Tput::Key::Up)).backward?.should be_true
      list.nav_intent(mk.call('\0', Tput::Key::Down)).forward?.should be_true
      list.nav_intent(mk.call('\0', Tput::Key::PageUp)).page_backward?.should be_true
      list.nav_intent(mk.call('\0', Tput::Key::CtrlF)).page_forward?.should be_true
      list.nav_intent(mk.call('\0', Tput::Key::Home)).first?.should be_true
      list.nav_intent(mk.call('\0', Tput::Key::End)).last?.should be_true
      list.nav_intent(mk.call('k', nil)).backward?.should be_true # vi
      list.nav_intent(mk.call('G', nil)).last?.should be_true     # vi
      list.nav_intent(mk.call('x', nil)).none?.should be_true
    end
  end
end
