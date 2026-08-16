require "./spec_helper"

include Crysterm

# A4-60 / §2.8: `single_step:` is the *only* constructor spelling across the
# ranged family, matching the `#single_step`/`#single_step=` accessors that
# were always the Qt name. The legacy `step:` doublet — a nilable alias that
# doubled every constructor's arity and hid the real default — is gone (no
# deprecation window: pre-1.0). Every constructor in the family carries the
# same contract, including `ProgressBar` and `Loading` (whose per-tick frame
# advance follows the same naming for consistency).

describe "A4-60 single_step: is the one ranged-constructor spelling" do
  it "SpinBox: single_step:, default 1" do
    s = headless_screen(80, 24)
    Widget::SpinBox.new(parent: s, single_step: 5).single_step.should eq 5
    Widget::SpinBox.new(parent: s).single_step.should eq 1
  end

  it "SpinBox: the constructor-given single_step drives #step_up" do
    s = headless_screen(80, 24)
    sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, single_step: 7
    sb.step_up
    sb.value.should eq 7
  end

  it "DoubleSpinBox: single_step:, default 1.0" do
    s = headless_screen(80, 24)
    Widget::DoubleSpinBox.new(parent: s, single_step: 0.5).single_step.should eq 0.5
    Widget::DoubleSpinBox.new(parent: s).single_step.should eq 1.0
  end

  it "Slider: single_step:, default 1" do
    s = headless_screen(80, 24)
    Widget::Slider.new(parent: s, single_step: 5).single_step.should eq 5
    Widget::Slider.new(parent: s).single_step.should eq 1
  end

  it "Dial: single_step:, default 1" do
    s = headless_screen(80, 24)
    Widget::Dial.new(parent: s, single_step: 5).single_step.should eq 5
    Widget::Dial.new(parent: s).single_step.should eq 1
  end

  it "ScrollBar: single_step:, default 1" do
    s = headless_screen(80, 24)
    Widget::ScrollBar.new(parent: s, single_step: 5).single_step.should eq 5
    Widget::ScrollBar.new(parent: s).single_step.should eq 1
  end

  it "ProgressBar: single_step:, default stays 5" do
    s = headless_screen(80, 24)
    Widget::ProgressBar.new(parent: s, single_step: 10).single_step.should eq 10
    Widget::ProgressBar.new(parent: s).single_step.should eq 5
  end

  it "Loading: frame advance takes single_step:, default 1" do
    s = headless_screen(80, 24)
    Widget::Loading.new(parent: s, single_step: 2).single_step.should eq 2
    Widget::Loading.new(parent: s).single_step.should eq 1
  end

  it "keeps the #single_step= writer coherent with the constructor keyword" do
    s = headless_screen(80, 24)
    sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, single_step: 2
    sb.single_step.should eq 2
    sb.single_step = 9
    sb.single_step.should eq 9
    sb.step_up
    sb.value.should eq 9
  end
end
