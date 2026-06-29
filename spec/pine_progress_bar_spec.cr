require "./spec_helper"

include Crysterm

private def ppb_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "Pine::ProgressBar" do
  it "defaults to the Pine percent-done look (text shown, [%p%] format, height 1)" do
    s = ppb_screen
    bar = Crysterm::Widget::Pine::ProgressBar.new parent: s
    bar.show_text?.should be_true
    bar.text_format.should eq "[%p%]"
    bar.height.should eq 1
  end

  it "derives #filled from a value set on the Pine subclass" do
    s = ppb_screen
    bar = Crysterm::Widget::Pine::ProgressBar.new parent: s
    bar.value = 45
    bar.filled.should eq 45

    bar.filled = 80
    bar.value.should eq 80
    bar.filled.should eq 80
  end

  it "clamps values into the inherited range" do
    s = ppb_screen
    bar = Crysterm::Widget::Pine::ProgressBar.new parent: s, minimum: 0, maximum: 100
    bar.value = 250
    bar.value.should eq 100
    bar.value = -50
    bar.value.should eq 0
  end
end
