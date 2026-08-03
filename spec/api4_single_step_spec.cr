require "./spec_helper"

include Crysterm

# A4-60: `single_step:` is the blessed Qt-parity constructor spelling across
# the ranged family (matching the `#single_step`/`#single_step=` accessors that
# were always the Qt name); `step:` stays accepted as a compatibility alias,
# with `single_step:` winning when both are given. Every constructor in the
# family carries the same contract, including `ProgressBar` (which already
# spelled it `single_step:` and now also takes the alias) and `Loading` (whose
# per-tick frame advance follows the same naming for consistency).

describe "A4-60 single_step:/step: constructor spellings" do
  it "SpinBox: accepts both spellings, single_step: wins, default 1" do
    s = headless_screen(80, 24)
    Widget::SpinBox.new(parent: s, single_step: 5).single_step.should eq 5
    Widget::SpinBox.new(parent: s, step: 4).single_step.should eq 4
    Widget::SpinBox.new(parent: s, single_step: 5, step: 4).single_step.should eq 5
    Widget::SpinBox.new(parent: s).single_step.should eq 1
  end

  it "SpinBox: the constructor-given single_step drives #step_up" do
    s = headless_screen(80, 24)
    sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, single_step: 7
    sb.step_up
    sb.value.should eq 7
  end

  it "DoubleSpinBox: accepts both spellings, single_step: wins, default 1.0" do
    s = headless_screen(80, 24)
    Widget::DoubleSpinBox.new(parent: s, single_step: 0.5).single_step.should eq 0.5
    Widget::DoubleSpinBox.new(parent: s, step: 0.25).single_step.should eq 0.25
    Widget::DoubleSpinBox.new(parent: s, single_step: 0.5, step: 0.25).single_step.should eq 0.5
    Widget::DoubleSpinBox.new(parent: s).single_step.should eq 1.0
  end

  it "Slider: accepts both spellings, single_step: wins, default 1" do
    s = headless_screen(80, 24)
    Widget::Slider.new(parent: s, single_step: 5).single_step.should eq 5
    Widget::Slider.new(parent: s, step: 4).single_step.should eq 4
    Widget::Slider.new(parent: s, single_step: 5, step: 4).single_step.should eq 5
    Widget::Slider.new(parent: s).single_step.should eq 1
  end

  it "Dial: accepts both spellings, single_step: wins, default 1" do
    s = headless_screen(80, 24)
    Widget::Dial.new(parent: s, single_step: 5).single_step.should eq 5
    Widget::Dial.new(parent: s, step: 4).single_step.should eq 4
    Widget::Dial.new(parent: s, single_step: 5, step: 4).single_step.should eq 5
    Widget::Dial.new(parent: s).single_step.should eq 1
  end

  it "ScrollBar: accepts both spellings, single_step: wins, default 1" do
    s = headless_screen(80, 24)
    Widget::ScrollBar.new(parent: s, single_step: 5).single_step.should eq 5
    Widget::ScrollBar.new(parent: s, step: 4).single_step.should eq 4
    Widget::ScrollBar.new(parent: s, single_step: 5, step: 4).single_step.should eq 5
    Widget::ScrollBar.new(parent: s).single_step.should eq 1
  end

  it "ProgressBar: gains the step: alias; single_step: wins, default stays 5" do
    s = headless_screen(80, 24)
    Widget::ProgressBar.new(parent: s, single_step: 10).single_step.should eq 10
    Widget::ProgressBar.new(parent: s, step: 8).single_step.should eq 8
    Widget::ProgressBar.new(parent: s, single_step: 10, step: 8).single_step.should eq 10
    Widget::ProgressBar.new(parent: s).single_step.should eq 5
  end

  it "Loading: frame advance takes both spellings, single_step: wins, default 1" do
    s = headless_screen(80, 24)
    Widget::Loading.new(parent: s, single_step: 2).single_step.should eq 2
    Widget::Loading.new(parent: s, step: 3).single_step.should eq 3
    Widget::Loading.new(parent: s, single_step: 2, step: 3).single_step.should eq 2
    Widget::Loading.new(parent: s).single_step.should eq 1
  end

  it "keeps the #single_step= writer coherent with the constructor keyword" do
    s = headless_screen(80, 24)
    sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, step: 2
    sb.single_step.should eq 2
    sb.single_step = 9
    sb.single_step.should eq 9
    sb.step_up
    sb.value.should eq 9
  end
end
