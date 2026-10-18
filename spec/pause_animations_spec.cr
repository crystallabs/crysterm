require "./spec_helper"

# `render.pause_when_unfocused` holds a window's animations while its
# terminal window is unfocused, and nothing else: `FrameClock#pause_while`
# is the gate a clock takes, `Widget#animations_paused?` what every clock a
# widget drives passes, and a change made while unfocused still paints.

private def paused_window(output = IO::Memory.new)
  Crysterm::Window.new input: IO::Memory.new, output: output, error: IO::Memory.new, width: 30, height: 4
end

describe "FrameClock#pause_while" do
  it "ticks nothing while the gate holds, and goes on once it opens" do
    held = true
    ticks = 0
    clock = Crysterm::FrameClock.ticker(10.milliseconds) { ticks += 1 }
    clock.pause_while { held }.should be clock
    clock.held?.should be_true
    clock.start
    sleep 60.milliseconds
    ticks.should eq 0
    clock.running?.should be_true
    held = false
    clock.held?.should be_false
    sleep 60.milliseconds
    ticks.should be > 0
    clock.stop
  end

  it "lets a tween that ran out while held complete on its first tick after" do
    held = true
    values = [] of Float64
    clock = Crysterm::FrameClock.tween(10.milliseconds, duration: 30.milliseconds) { |c| values << c.value }
    clock.pause_while { held }
    clock.start
    sleep 80.milliseconds
    values.should be_empty
    clock.running?.should be_true
    held = false
    sleep 50.milliseconds
    values.should eq [1.0]
    clock.completed?.should be_true
    clock.running?.should be_false
  end

  it "is not held without a gate" do
    Crysterm::FrameClock.ticker(10.milliseconds) { }.held?.should be_false
  end
end

describe "Window#animations_paused?" do
  it "holds while the terminal is unfocused and the pause is on" do
    s = paused_window
    begin
      s.pause_when_unfocused?.should be_true # config default
      s.animations_paused?.should be_false   # assumed focused until told otherwise
      s.dispatch_mouse ::Tput::Mouse::Event.blur
      s.animations_paused?.should be_true
      s.pause_when_unfocused = false
      s.animations_paused?.should be_false
      s.pause_when_unfocused = true
      s.animations_paused?.should be_true
      s.dispatch_mouse ::Tput::Mouse::Event.focus
      s.animations_paused?.should be_false
    ensure
      s.destroy
    end
  end

  it "paints a change made while unfocused" do
    outp = IO::Memory.new
    s = paused_window(outp)
    begin
      box = Crysterm::Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "ORIG"
      s.repaint
      s.dispatch_mouse ::Tput::Mouse::Event.blur
      outp.clear
      box.content = "CHANGED"
      s.update
      sleep 80.milliseconds
      outp.to_s.should contain "CHANGED"
    ensure
      s.destroy
    end
  end

  it "holds a widget's pulse while unfocused, and lets it breathe again on focus-in" do
    s = paused_window
    begin
      box = Crysterm::Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 1, content: "x"
      s.repaint
      box.animations_paused?.should be_false
      s.dispatch_mouse ::Tput::Mouse::Event.blur
      box.animations_paused?.should be_true
      clock = box.pulse(0.0, 1.0, 0.2.seconds, fps: 50)
      clock.held?.should be_true
      sleep 60.milliseconds
      box.style.opacity?.should be_nil # no tick set it
      s.dispatch_mouse ::Tput::Mouse::Event.focus
      clock.held?.should be_false
      sleep 60.milliseconds
      box.style.opacity?.should_not be_nil
      box.stop_fade
    ensure
      s.destroy
    end
  end

  it "does not hold a widget in no window" do
    Crysterm::Widget::Box.new(content: "x").animations_paused?.should be_false
  end
end
