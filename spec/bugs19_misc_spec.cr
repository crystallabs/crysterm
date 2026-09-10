require "./spec_helper"

describe "Bug #4: Action.parse_key_stroke on empty chord part" do
  it "raises ArgumentError on Ctrl+ (trailing empty part)" do
    expect_raises(ArgumentError, /empty chord part/) do
      Crysterm::Action.parse_key_stroke("Ctrl+")
    end
  end

  it "raises ArgumentError on leading + (empty first part)" do
    expect_raises(ArgumentError, /empty chord part/) do
      Crysterm::Action.parse_key_stroke("+K")
    end
  end

  it "raises ArgumentError on ++ (empty middle part)" do
    expect_raises(ArgumentError, /empty chord part/) do
      Crysterm::Action.parse_key_stroke("Ctrl++")
    end
  end
end

describe "Bug #36: DialogButtonBox.add_button validation" do
  it "raises ArgumentError for combined flags (Ok | Cancel)" do
    box = Crysterm::Widget::DialogButtonBox.new
    expect_raises(ArgumentError, /single StandardButton/) do
      box.add_button(Crysterm::Widget::DialogButtonBox::StandardButton::Ok | Crysterm::Widget::DialogButtonBox::StandardButton::Cancel)
    end
  end

  it "raises ArgumentError for None flag" do
    box = Crysterm::Widget::DialogButtonBox.new
    expect_raises(ArgumentError, /single StandardButton/) do
      box.add_button(Crysterm::Widget::DialogButtonBox::StandardButton::None)
    end
  end

  it "succeeds for single StandardButton" do
    box = Crysterm::Widget::DialogButtonBox.new
    button = box.add_button(Crysterm::Widget::DialogButtonBox::StandardButton::Ok)
    button.should_not be_nil
  end
end

describe "Bug #37: GaugeList::Item#value= on unowned item" do
  it "stores finite value even when unowned" do
    item = Crysterm::Widget::GaugeList::Item.new "cpu", 0.0, 1
    item.value = 42
    item.value.should eq(42.0)
  end

  it "stores finite value set after construction" do
    item = Crysterm::Widget::GaugeList::Item.new "cpu", 0.0, 1
    item.value = 3.14
    item.value.should eq(3.14)
  end

  it "falls back to 0.0 for NaN on unowned item" do
    item = Crysterm::Widget::GaugeList::Item.new "cpu", 0.0, 1
    item.value = Float64::NAN
    item.value.should eq(0.0)
  end

  it "falls back to 0.0 for Infinity on unowned item" do
    item = Crysterm::Widget::GaugeList::Item.new "cpu", 0.0, 1
    item.value = Float64::INFINITY
    item.value.should eq(0.0)
  end
end

describe "Bug #38: LCDNumber#display(Int) with out-of-range values" do
  it "does not raise for UInt64::MAX and keeps the float value" do
    lcd = Crysterm::Widget::LCDNumber.new
    lcd.display(UInt64::MAX)
    lcd.value.should eq(UInt64::MAX.to_f)
    lcd.text.should eq(UInt64::MAX.to_s)
  end

  it "does not raise for a large Int128 value" do
    lcd = Crysterm::Widget::LCDNumber.new
    large_int = Int128.new(Int64::MAX) + 1000
    lcd.display(large_int)
    lcd.value.should eq(large_int.to_f)
  end

  it "does not re-format an out-of-range value on mode change" do
    lcd = Crysterm::Widget::LCDNumber.new
    lcd.display(UInt64::MAX)
    lcd.mode = :hex
    lcd.text.should eq(UInt64::MAX.to_s)
  end

  it "still re-formats an in-range value on mode change" do
    lcd = Crysterm::Widget::LCDNumber.new
    lcd.display(42)
    lcd.mode = :hex
    lcd.text.should eq("2A")
  end
end
