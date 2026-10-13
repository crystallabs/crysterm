require "./spec_helper"

# The macOS Ghostty launcher: a new Ghostty instance per window, given the
# command as `--initial-command` through `open -na Ghostty --args`, placed by
# `--window-position-x/y` and sized in cells, its frame read from the window
# server by the instance's pid. String checks only: nothing runs `open`,
# `ps` or `osascript`.
describe "Crysterm::Terminal Ghostty launcher" do
  inner = ["env", "CRYSTERM_WINDOW_HELPER=/tmp/x y.sock", "/bin/md"]

  it "opens a new instance running the command, which quits with its window" do
    args = Crysterm::Terminal.ghostty_arguments(inner, 100, 30)
    args[0, 3].should eq(["-na", "Ghostty", "--args"])
    args.should contain("--quit-after-last-window-closed=true")
    args.should contain("--window-save-state=never")
    args.should contain("--window-width=100")
    args.should contain("--window-height=30")
    args.none?(&.starts_with?("--window-position")).should be_true
    args.none?(&.starts_with?("--title")).should be_true
    # One shell command line, quoted, and not `exec`ed: Ghostty runs it
    # as `exec -l <command>` itself.
    args.last.should eq("--initial-command=env 'CRYSTERM_WINDOW_HELPER=/tmp/x y.sock' /bin/md")
  end

  it "places a window when given a position" do
    args = Crysterm::Terminal.ghostty_arguments(inner, 80, 24, {120, -5})
    args.should contain("--window-position-x=120")
    args.should contain("--window-position-y=-5")
    args.last.should start_with("--initial-command=")
  end

  it "turns a frame into a position in the visible area and a size in cells" do
    # 80 by 24 cells of 8 by 17 points make a 648 by 448 frame (1.3.1).
    Crysterm::Terminal.ghostty_placement({400, 70, 648, 448}, 100, 30, {0, 30}, {8.0, 17.0})
      .should eq({400, 40, 80, 24})
    Crysterm::Terminal.ghostty_placement({420, 90, 488, 295}, 100, 30, {0, 30}, {8.0, 17.0})
      .should eq({420, 60, 60, 15})
    # Without a cell size, the size asked for stays.
    Crysterm::Terminal.ghostty_placement({400, 70, 648, 448}, 100, 30, {70, 25}, nil)
      .should eq({330, 45, 100, 30})
    # Never under Ghostty's smallest window, 10 by 4.
    Crysterm::Terminal.ghostty_placement({0, 0, 20, 45}, 80, 24, {0, 0}, {8.0, 17.0})
      .should eq({0, 0, 10, 4})
  end

  it "finds the Ghostty instance a tty's process descends from" do
    processes = <<-PS
          1     0 ??       /sbin/launchd
       2823     1 ??       /Applications/Ghostty.app/Contents/MacOS/ghostty
       2825  2823 ttys005  /usr/bin/login
       2826  2825 ttys005  /bin/sh
       5000     1 ??       /Applications/Some App.app/Contents/MacOS/Some App
       5001  5000 ttys009  /bin/zsh
      PS
    Crysterm::Terminal.ghostty_instance("/dev/ttys005", processes).should eq(2823)
    Crysterm::Terminal.ghostty_instance("ttys005", processes).should eq(2823)
    Crysterm::Terminal.ghostty_instance("/dev/ttys009", processes).should be_nil
    Crysterm::Terminal.ghostty_instance("/dev/ttys001", processes).should be_nil
    Crysterm::Terminal.ghostty_instance("/dev/ttys005", "garbage\n\n").should be_nil
  end

  it "reads the instance's one on-screen window from the window server" do
    script = Crysterm::Terminal.ghostty_frame_script(2823)
    script.should contain("CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly")
    script.should contain("w.kCGWindowOwnerPID == 2823 && w.kCGWindowLayer == 0")
    script.should contain("b.length == 1 ?")
    script.should_not contain("tell application")
    Crysterm::Terminal::JXA_COMMAND.should eq(["osascript", "-l", "JavaScript", "-e"])
  end

  {% if flag?(:darwin) %}
    it "is a macOS launcher that places windows and reads their frames" do
      ghostty = Crysterm::Terminal::LAUNCHERS.find! { |l| l.name == "ghostty" }
      ghostty.frame_geometry_supported?.should be_true
      argv = ghostty.argv_for(inner, 90, 20, "t").not_nil!
      argv[0, 4].should eq(["open", "-na", "Ghostty", "--args"])
      argv.should contain("--window-width=90")
    end
  {% end %}
end
