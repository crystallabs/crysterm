require "./spec_helper"

include Crysterm

# Regression specs for the Direct-mode probe gate — same bug class as the probe
# race pinned in `spec/bugs17_probe_race_spec.cr`, applied to `Direct` instead
# of `Window`.
#
# `Direct.new` accepts an already-built shared `screen:` device (mirrors
# `Window`'s adoption pattern). The constructor must not run `@screen.probe`
# unconditionally: adopting an already-probed device — or one with a live input
# listener started by a sibling `Window` on the same device — would re-run the
# live negotiation, redundant when already probed and racing the sibling's
# `tput.listen` fiber for the same reply bytes when live.
#
# Headless probing no-ops at the tput layer (`probe_capable?` is false on
# `IO::Memory`), so the byte capture alone cannot witness the call — the spy
# below counts `Screen#probe` invocations to give the specs teeth.

# Records `Screen#probe` invocations.
private class DPGSpyScreen < Crysterm::Screen
  getter probe_calls = 0

  def probe : Nil
    @probe_calls += 1
    super
  end
end

private def dpg_device
  DPGSpyScreen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10)
end

describe "Direct-mode probe gate" do
  it "still probes exactly once when adopting a standalone-built device" do
    dev = dpg_device
    dev.probe_calls.should eq 0
    dev.probed?.should be_false
    Crysterm::Direct.new(screen: dev)
    dev.probe_calls.should eq 1
    dev.probed?.should be_true
  end

  it "does not re-probe when adopting an already-probed shared device" do
    dev = dpg_device
    Crysterm::Direct.new(screen: dev)
    dev.probe_calls.should eq 1

    # A second `Direct` session sharing the same already-probed device (the
    # documented adoption pattern) must not repeat the live negotiation.
    Crysterm::Direct.new(screen: dev)
    dev.probe_calls.should eq 1
  end

  it "does not re-probe an unprobed device with a live sibling input fiber" do
    dev = dpg_device
    w = Crysterm::Window.new(screen: dev, probe: false, default_quit_keys: false)
    begin
      dev.probed?.should be_false
      w.start_input
      dev.listening?.should be_true

      # `Direct.new` adopting the same device must skip the probe even though
      # `probed?` is still false — `listening?` alone must gate here, exactly
      # as it does for `Window` (B17-01).
      Crysterm::Direct.new(screen: dev)
      dev.probe_calls.should eq 0
    ensure
      w.destroy
    end
  end
end
