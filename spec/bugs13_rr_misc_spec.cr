require "./spec_helper"

# Regression spec for two BUGS13 findings:
#
#   R1 — the GNU `screen` launcher had been mechanically renamed to "window"
#        (a `screen`->`window` rename casualty), so it was registered under a
#        nonexistent binary name and built argv ["window", ...] — dead on both
#        the registry path and the `-e` fallback (screen doesn't take `-e`).
#   R5 — `Crysterm::VERSION` said 0.1.0 while shard.yml says 1.0.0.

include Crysterm

describe "BUGS13 R1 — GNU screen launcher execs `screen`, not `window`" do
  it "registers the multiplexer under its real binary name" do
    names = Crysterm::Terminal::LAUNCHERS.map(&.name)
    names.should contain "screen"
    names.should_not contain "window" # the rename casualty must be gone
  end

  it "builds a screen argv (with -t title when given)" do
    screen = Crysterm::Terminal::LAUNCHERS.find! { |l| l.name == "screen" }
    screen.argv_for(["/bin/true", "arg"], 80, 24, "mytitle")
      .should eq ["screen", "-t", "mytitle", "/bin/true", "arg"]
    screen.argv_for(["/bin/true"], 80, 24, nil)
      .should eq ["screen", "/bin/true"]
  end
end

describe "BUGS13 R5 — Crysterm::VERSION matches shard.yml" do
  it "agrees with the shard.yml version" do
    shard_version = File.read(File.join(__DIR__, "..", "shard.yml"))
      .lines.find!(&.starts_with?("version:")).split(':', 2)[1].strip
    Crysterm::VERSION.should eq shard_version
    Crysterm::VERSION.should eq "1.0.0"
  end
end
