require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# Alignment padding uses `Style#fill_char` instead of a hardcoded space
# (see todoc Q5). Default fill char is a space, so existing alignment is unchanged.
describe "Widget#_align fill char" do
  it "pads right alignment with a space by default" do
    box = Widget::Box.new parent: headless_screen, width: 10, height: 1
    box._align("hi", 6, Tput::AlignFlag::Right).should eq "    hi"
  end

  it "pads with the configured fill char for right alignment" do
    box = Widget::Box.new parent: headless_screen, width: 10, height: 1
    box.style.fill_char = '.'
    box._align("hi", 6, Tput::AlignFlag::Right).should eq "....hi"
  end

  it "pads both sides for center alignment with the fill char" do
    box = Widget::Box.new parent: headless_screen, width: 10, height: 1
    box.style.fill_char = '.'
    box._align("hi", 6, Tput::AlignFlag::HCenter).should eq "..hi.."
  end
end
