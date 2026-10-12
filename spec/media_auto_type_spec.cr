require "./spec_helper"

include Crysterm

# A terminal handle whose graphics facts are only the ones the spec sets: no
# live probe, and the identity read from the environment (an iTerm2 running
# the specs) cleared.
private def plain_tput
  ti = (Unibilium.from_env rescue Unibilium.from_terminal("xterm"))
  tput = Tput.new(terminfo: ti, input: STDIN, output: STDOUT, probe: false)
  tput.emulator.iterm2 = false
  tput.emulator.kitty = false
  tput
end

# `Media.auto_type`: what automatic backend selection picks, asked whatever
# `media.backend` pins — for a UI naming it beside the pinned choice — and
# `Type#backend`, the `Backend` member (and so the label) of a type.
describe "Widget::Media.auto_type" do
  it "answers what auto-detection picks even while a backend is pinned" do
    tput = plain_tput
    tput.emulator.kitty = true
    begin
      Crysterm::Config.media_backend = Widget::Media::Backend::AnsiC16
      Widget::Media.resolve(Widget::Media::Content::Image, tput).should eq Widget::Media::Type::AnsiC16
      Widget::Media.auto_type(Widget::Media::Content::Image, tput).should eq Widget::Media::Type::Kitty

      # The same ranking `resolve` walks under Auto: by content, and past
      # what media.exclude names.
      tput.emulator.iterm2 = true
      Widget::Media.auto_type(Widget::Media::Content::AnimatedImage, tput).should eq Widget::Media::Type::Iterm
      Crysterm::Config.set "media.exclude", "kitty,iterm,sixel"
      Widget::Media.auto_type(Widget::Media::Content::Image, tput).family.should eq Widget::Media::Family::Cells

      Crysterm::Config.media_backend = Widget::Media::Backend::Auto
      Widget::Media.resolve(Widget::Media::Content::Image, tput)
        .should eq Widget::Media.auto_type(Widget::Media::Content::Image, tput)
    ensure
      Crysterm::Config.reset "media.backend"
      Crysterm::Config.reset "media.exclude"
    end
  end

  it "names a type through its Backend member" do
    Widget::Media::Type::Kitty.backend.should eq Widget::Media::Backend::Kitty
    Widget::Media::Type::Kitty.backend.label.should eq "Kitty graphics"
    Widget::Media::Type.each do |t|
      t.backend.type.should eq t
    end
  end
end
