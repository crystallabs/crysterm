require "./spec_helper"

include Crysterm

describe "Pine::ProgressBar" do
  it "defaults to the Pine percent-done look (text shown, [%p%] format, height 1)" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::Pine::ProgressBar.new parent: s
    bar.text_visible?.should be_true
    bar.format.should eq "[%p%]"
    bar.height_spec.should eq 1
  end

  it "derives #percent from a value set on the Pine subclass" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::Pine::ProgressBar.new parent: s
    bar.value = 45
    bar.percent.should eq 45

    bar.percent = 80
    bar.value.should eq 80
    bar.percent.should eq 80
  end

  it "clamps values into the inherited range" do
    s = headless_screen(80, 24)
    bar = Crysterm::Widget::Pine::ProgressBar.new parent: s, minimum: 0, maximum: 100
    bar.value = 250
    bar.value.should eq 100
    bar.value = -50
    bar.value.should eq 0
  end
end
