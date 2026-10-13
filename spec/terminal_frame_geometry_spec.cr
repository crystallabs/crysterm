require "./spec_helper"

# Frame geometry of spawned windows (`Window.open(frame:)`,
# `Window#frame_geometry`): Terminal.app and iTerm2 place a new window and
# read its frame back through AppleScript, Ghostty through its options and
# the window server (terminal_ghostty_launcher_spec.cr); no other launcher
# can. String
# checks on the generated scripts only: nothing runs `osascript`.
describe "Crysterm::Terminal frame geometry" do
  inner = ["env", "CRYSTERM_WINDOW_HELPER=/tmp/x.sock", "/bin/md"]

  it "places a Terminal.app window only when given a frame" do
    plain = Crysterm::Terminal.terminal_app_script(inner, 80, 24, "t")
    plain.should_not contain("bounds")
    placed = Crysterm::Terminal.terminal_app_script(inner, 80, 24, "t", {100, 50, 640, 480})
    placed.should contain("set bounds of (first window whose selected tab is t) to {100, 50, 740, 530}")
    # The bounds come after the size, so the frame decides the size.
    placed.index!("set bounds").should be > placed.index!("set number of rows")
    placed.should contain("set custom title of t to \"t\"")
  end

  it "places an iTerm2 window only when given a frame" do
    plain = Crysterm::Terminal.iterm2_script(inner, 80, 24, nil)
    plain.should_not contain("bounds")
    placed = Crysterm::Terminal.iterm2_script(inner, 80, 24, nil, {0, 25, 800, 600})
    placed.should contain("set bounds of w to {0, 25, 800, 625}")
    placed.should contain("  try\n    set bounds")
  end

  it "reads a frame back by the window's tty, without starting the application" do
    terminal = Crysterm::Terminal.terminal_app_frame_script("/dev/ttys004")
    terminal.should start_with("if application \"Terminal\" is running then")
    terminal.should contain("if tty of t is \"/dev/ttys004\" then return bounds of w")
    iterm = Crysterm::Terminal.iterm2_frame_script("/dev/ttys005")
    iterm.should start_with("if application \"iTerm2\" is running then")
    iterm.should contain("repeat with s in sessions of t")
    iterm.should contain("if tty of s is \"/dev/ttys005\" then return bounds of w")
  end

  it "parses osascript's bounds into x, y, width, height" do
    Crysterm::Terminal.parse_bounds("544, 588, 1582, 1162\n").should eq({544, 588, 1038, 574})
    Crysterm::Terminal.parse_bounds("").should be_nil
    Crysterm::Terminal.parse_bounds("1, 2, 3").should be_nil
    Crysterm::Terminal.parse_bounds("10, 10, 5, 20").should be_nil
  end

  it "reads a frame through the reader's command, giving up on one that does not answer" do
    sh = ["sh", "-c"]
    Crysterm::Terminal.read_frame("echo '10, 20, 110, 70'", sh).should eq({10, 20, 100, 50})
    Crysterm::Terminal.read_frame("echo garbage", sh).should be_nil
    Crysterm::Terminal.read_frame("echo '1, 2, 3, 4'; exit 1", sh).should be_nil
    started = Time.instant
    Crysterm::Terminal.read_frame("exec sleep 10", sh, 100.milliseconds).should be_nil
    (Time.instant - started).should be < 2.seconds
  end

  it "reports which launchers can place and read windows" do
    Crysterm::Terminal::LAUNCHERS.each do |launcher|
      supported = launcher.name.in?("terminal.app", "iterm2", "ghostty")
      launcher.frame_geometry_supported?.should eq(supported)
    end
    xterm = Crysterm::Terminal::LAUNCHERS.find! { |l| l.name == "xterm" }
    xterm.frame_geometry("/dev/pts/1").should be_nil
  end

  it "says why an unsupported launcher cannot" do
    plain = Crysterm::Terminal::Launcher.flags("sh", run_flag: "-c")
    reason = Crysterm::Terminal.frame_geometry_refusal(plain)
    reason.should_not be_nil
    reason.not_nil!.should contain("sh cannot place its windows")
    Crysterm::Window.frame_geometry_supported?(plain).should be_false
  end

  {% if flag?(:darwin) %}
    it "supports Terminal.app on macOS" do
      terminal = Crysterm::Terminal::LAUNCHERS.find! { |l| l.name == "terminal.app" }
      Crysterm::Terminal.frame_geometry_refusal(terminal).should be_nil if terminal.available?
    end
  {% end %}

  it "has no frame for a window it did not open" do
    window = headless_screen
    begin
      window.frame_geometry.should be_nil
      window.frame_geometry_supported?.should be_false
    ensure
      window.destroy
    end
  end

  it "passes a frame to a launcher's placing spawner, and none otherwise" do
    seen = [] of Crysterm::Terminal::Frame?
    command = ->(i : Array(String), _c : Int32, _r : Int32, _t : String?) { ["true"] + i }
    placed = ->(_i : Array(String), _c : Int32, _r : Int32, _t : String?, f : Crysterm::Terminal::Frame) do
      seen << f
      Process.new("true")
    end
    reader = ->(_tty : String) { {1, 2, 3, 4}.as(Crysterm::Terminal::Frame?) }
    launcher = Crysterm::Terminal::Launcher.new("fake", command, placed_spawn: placed, frame_reader: reader)
    launcher.frame_geometry_supported?.should be_true
    launcher.frame_geometry("/dev/ttys001").should eq({1, 2, 3, 4})
    launcher.launch(["x"], 80, 24, nil, {5, 6, 7, 8}).wait
    launcher.launch(["x"], 80, 24, nil).wait
    seen.should eq([{5, 6, 7, 8}])
  end
end
