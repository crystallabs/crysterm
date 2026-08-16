require "./spec_helper"

include Crysterm

# Alignment padding uses `Style#fill_char` instead of a hardcoded space
# (see todoc Q5). Default fill char is a space, so existing alignment is unchanged.
describe "Widget#align_line fill char" do
  it "pads right alignment with a space by default" do
    box = Widget::Box.new parent: headless_screen(default_quit_keys: true), width: 10, height: 1
    box.align_line("hi", 6, Tput::AlignFlag::Right).should eq "    hi"
  end

  it "pads with the configured fill char for right alignment" do
    box = Widget::Box.new parent: headless_screen(default_quit_keys: true), width: 10, height: 1
    box.style.fill_char = '.'
    box.align_line("hi", 6, Tput::AlignFlag::Right).should eq "....hi"
  end

  it "pads both sides for center alignment with the fill char" do
    box = Widget::Box.new parent: headless_screen(default_quit_keys: true), width: 10, height: 1
    box.style.fill_char = '.'
    box.align_line("hi", 6, Tput::AlignFlag::HCenter).should eq "..hi.."
  end
end
