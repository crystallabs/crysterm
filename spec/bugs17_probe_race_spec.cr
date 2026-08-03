require "./spec_helper"

include Crysterm

# Regression specs for BUGS17 finding B17-01 — the shared-device probe race:
#
# Constructing a sibling `Window` on a live shared `Screen`
# (`Window.new(screen: dev)`, the documented multi-window pattern) must not
# re-run the device probe: the probe's synchronous reply reads would race the
# existing sibling's input fiber — parked in `tput.listen` on the same fd —
# for the same bytes. Stolen replies get dispatched as garbage key events
# while the probe times out into degraded capabilities, and the probe's
# query/cleanup writes paint over the sibling's frame. A device passed via
# `screen:` was already probed by its first window's constructor, so the
# re-probe is redundant even when it does not race. The twin site is
# `Window#screen=` adopting an already-live device.
#
# Headless probing no-ops at the tput layer (`probe_capable?` is false on
# `IO::Memory`), so the byte capture alone cannot witness the call — the spy
# below counts `Screen#probe` invocations to give the specs teeth.

# Records `Screen#probe` invocations and the probe/input-fiber call order.
private class B17prSpyScreen < Crysterm::Screen
  getter probe_calls = 0
  getter ops = [] of String

  def probe : Nil
    @probe_calls += 1
    @ops << "probe"
    super
  end

  def stop_input : Nil
    @ops << "stop_input"
    super
  end

  def start_input : Nil
    @ops << "start_input"
    super
  end
end

private def b17pr_device
  B17prSpyScreen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10)
end

private def b17pr_window(dev)
  Crysterm::Window.new(screen: dev, default_quit_keys: false)
end

# Escape sequences `Tput::Probe#build_probe_query` writes (OSC 10/11 color
# queries, DECRQSS SGR/DECSCUSR readbacks, CPR, DA1). None may appear in
# output emitted while a sibling window is constructed on a live device.
private B17PR_PROBE_QUERIES = ["\e]10;?", "\e]11;?", "\eP$qm", "\eP$q q", "\e[6n", "\e[c"]

describe "BUGS17 B17-01: shared-device probe race" do
  it "does not re-probe (nor emit probe queries) when a sibling is constructed on a probed live device" do
    dev = b17pr_device
    w1 = b17pr_window dev
    begin
      dev.probe_calls.should eq 1
      dev.probed?.should be_true

      # Input fiber live on the shared device — the racing reader of the bug.
      w1.start_input
      dev.listening?.should be_true

      out = dev.output.as(IO::Memory)
      out.clear
      w2 = b17pr_window dev
      begin
        # The sibling's constructor must not re-run `@screen.probe` (nor
        # `detect_cell_geometry`) on the live device.
        dev.probe_calls.should eq 1

        # Nothing written between the constructions may be a probe query.
        emitted = out.to_s
        B17PR_PROBE_QUERIES.each do |q|
          emitted.includes?(q).should be_false
        end

        # The sibling still gets the shared device's dimensions and caps.
        w2.awidth.should eq 40
        w2.aheight.should eq 10
        w2.draw_caps.should eq dev.draw_caps
        w2.colors.should eq dev.colors
      ensure
        w2.destroy
      end
    ensure
      w1.destroy
    end
  end

  it "does not re-probe an already-probed shared device even without a live input fiber" do
    dev = b17pr_device
    w1 = b17pr_window dev
    w2 = b17pr_window dev
    begin
      # No input fiber was ever started; the `probed?` flag alone must gate.
      dev.listening?.should be_false
      dev.probe_calls.should eq 1
    ensure
      w1.destroy
      w2.destroy
    end
  end

  it "still probes exactly once when the first window adopts a standalone-built device" do
    dev = b17pr_device
    dev.probe_calls.should eq 0
    dev.probed?.should be_false
    # `Screen.new` defers its probe, so the FIRST window on a standalone-built
    # device must run it (the gate must not be "a screen: arg was passed").
    w = b17pr_window dev
    begin
      dev.probe_calls.should eq 1
      dev.probed?.should be_true
    ensure
      w.destroy
    end
  end

  it "keeps probe: false deferring the probe entirely" do
    dev = b17pr_device
    w = Crysterm::Window.new(screen: dev, probe: false, default_quit_keys: false)
    begin
      dev.probe_calls.should eq 0
      dev.probed?.should be_false
    ensure
      w.destroy
    end
  end

  it "screen= does not re-probe when adopting an already-probed live device" do
    dev2 = b17pr_device
    w2 = b17pr_window dev2
    w = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 30, height: 8, default_quit_keys: false)
    begin
      w2.start_input
      dev2.probe_calls.should eq 1

      out = dev2.output.as(IO::Memory)
      out.clear
      w.screen = dev2
      # `screen=` must not run `reprobe_and_detect_geometry` unconditionally on
      # the adopted, already-listening device.
      dev2.probe_calls.should eq 1
      emitted = out.to_s
      B17PR_PROBE_QUERIES.each do |q|
        emitted.includes?(q).should be_false
      end
      # The migrated window adopts the shared device's geometry.
      w.awidth.should eq 40
      w.aheight.should eq 10
    ensure
      w.destroy
      w2.destroy
    end
  end

  it "reprobe_and_detect_geometry serializes a genuine re-probe against the input fiber" do
    dev = b17pr_device
    dev.start_input
    dev.listening?.should be_true

    # The explicit-reprobe path must keep the documented ordering
    # "stop old input → probe → detect_cell_geometry → start_input"...
    dev.reprobe_and_detect_geometry
    dev.ops.should eq ["start_input", "stop_input", "probe", "start_input"]
    dev.probed?.should be_true
    # ...and leave the device listening, as it was before.
    dev.listening?.should be_true
  end
end
