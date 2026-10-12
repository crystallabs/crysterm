require "./spec_helper"

# A second window joining a running `Application#exec(window)` loop
# (`Application#show`, Qt's `QWindow::show` for a window made while the loop
# runs), the loop's quitOnLastWindowClosed semantics with it, the asking
# close (`Window#try_close`, Qt's `QWidget::close`), and the environment
# detection behind `Window.open` (`Terminal.graphical?`,
# `Terminal.current_emulator`). All headless.

private def headless_window
  Crysterm::Window.new input: IO::Memory.new, output: IO::Memory.new, width: 40, height: 10
end

# Runs *app*'s loop on *first* in a fiber and returns the channel its status
# lands on, once the loop is listening.
private def exec_in_fiber(app, first)
  status = Channel(Int32).new(1)
  spawn { status.send app.exec(first) }
  sleep 20.milliseconds
  status
end

private def still_running?(status)
  select
  when status.receive
    false
  when timeout(50.milliseconds)
    true
  end
end

private def ended_with(status)
  select
  when s = status.receive
    s
  when timeout(2.seconds)
    fail "the loop did not end"
  end
end

describe "Application#show" do
  it "adds a window to the running loop, which runs until the last window is gone" do
    app = Crysterm::Application.new
    first = headless_window
    second = headless_window
    begin
      status = exec_in_fiber app, first
      app.show(second).should be second
      app.windows.should eq [first, second]
      second.application.should be app
      second.screen.listening?.should be_true

      first.destroy # the first window closing leaves the second running
      still_running?(status).should be_true
      app.windows.should eq [second]

      second.destroy # the last one ends the loop
      ended_with(status).should eq 0
    ensure
      first.destroy
      second.destroy
    end
  end

  it "routes a quit from a later window through the application, tearing every window down" do
    app = Crysterm::Application.new
    first = headless_window
    second = headless_window
    begin
      status = exec_in_fiber app, first
      app.show second
      second.quit 3
      ended_with(status).should eq 3
      first.destroyed?.should be_true
      second.destroyed?.should be_true
    ensure
      first.destroy
      second.destroy
    end
  end

  it "registers, renders and listens outside a loop too" do
    app = Crysterm::Application.new
    w = headless_window
    begin
      app.show w
      app.windows.should eq [w]
      w.screen.listening?.should be_true
    ensure
      w.destroy
    end
  end
end

describe "Application#exec watching for output failures" do
  it "watches each window once, however often it is shown, and a window added before the loop from its start" do
    app = Crysterm::Application.new
    first = headless_window
    early = headless_window
    late = headless_window
    begin
      app.add early
      early.handlers(Crysterm::Event::OutputFailed).size.should eq 0
      status = exec_in_fiber app, first
      # Every window registered when the loop started is watched.
      first.handlers(Crysterm::Event::OutputFailed).size.should eq 1
      early.handlers(Crysterm::Event::OutputFailed).size.should eq 1
      # Showing a window again adds no second watch.
      app.show late
      app.show late
      app.show first
      late.handlers(Crysterm::Event::OutputFailed).size.should eq 1
      first.handlers(Crysterm::Event::OutputFailed).size.should eq 1
      # A window removed from the application is unwatched with it.
      app.remove late
      late.handlers(Crysterm::Event::OutputFailed).size.should eq 0

      app.quit 0
      ended_with(status).should eq 0
      # The loop's end took every watch down.
      early.handlers(Crysterm::Event::OutputFailed).size.should eq 0
    ensure
      first.destroy
      early.destroy
      late.destroy
    end
  end
end

describe "Window#try_close" do
  it "closes when no handler objects, and tells" do
    w = headless_window
    closed = false
    w.on(Crysterm::Event::WindowClosed) { closed = true }
    w.try_close.should be_true
    closed.should be_true
    w.destroyed?.should be_true
    w.try_close.should be_false # already gone
  end

  it "honors an ignored CloseRequest" do
    w = headless_window
    begin
      asked = 0
      w.on(Crysterm::Event::CloseRequest) do |e|
        asked += 1
        e.ignore
      end
      w.try_close.should be_false
      asked.should eq 1
      w.destroyed?.should be_false
      w.connected?.should be_true
    ensure
      w.destroy
    end
  end
end

# Runs the block with the environment the detection reads set to *values*
# (the config mirrors of the variables, and the emulators' own marks in the
# process environment), everything put back afterwards.
private def with_environment(tmux : String? = nil, sty : String? = nil, term_program : String? = nil,
                             display : String? = nil, wayland_display : String? = nil,
                             marks : Hash(String, String) = {} of String => String, &)
  config = Crysterm::Config
  previous = {config.environment_tmux, config.environment_sty, config.environment_term_program,
              config.environment_display, config.environment_wayland_display}
  saved_marks = Crysterm::Terminal::EMULATOR_VARIABLES.keys.push("VTE_VERSION").to_h { |k| {k, ENV[k]?} }
  begin
    config.environment_tmux = tmux
    config.environment_sty = sty
    config.environment_term_program = term_program
    config.environment_display = display
    config.environment_wayland_display = wayland_display
    saved_marks.each_key { |k| ENV.delete k }
    marks.each { |k, v| ENV[k] = v }
    yield
  ensure
    config.environment_tmux, config.environment_sty, config.environment_term_program, config.environment_display, config.environment_wayland_display = previous
    saved_marks.each do |k, v|
      if v
        ENV[k] = v
      else
        ENV.delete k
      end
    end
  end
end

describe "Terminal.current_emulator" do
  it "names the multiplexer first, then TERM_PROGRAM, then the emulators' own marks" do
    with_environment(tmux: "/tmp/tmux-1000/default,1,0", term_program: "iTerm.app") do
      Crysterm::Terminal.current_emulator(ancestors: false).should eq "tmux"
    end
    with_environment(sty: "1234.pts-0.host", marks: {"KITTY_WINDOW_ID" => "1"}) do
      Crysterm::Terminal.current_emulator(ancestors: false).should eq "screen"
    end
    with_environment(term_program: "Apple_Terminal", marks: {"KITTY_WINDOW_ID" => "1"}) do
      Crysterm::Terminal.current_emulator(ancestors: false).should eq "terminal.app"
    end
    with_environment(term_program: "WezTerm") do
      Crysterm::Terminal.current_emulator(ancestors: false).should eq "wezterm"
    end
    with_environment(term_program: "SomethingElse") do
      Crysterm::Terminal.current_emulator(ancestors: false).should eq "somethingelse"
    end
    with_environment(marks: {"KONSOLE_VERSION" => "230800"}) do
      Crysterm::Terminal.current_emulator(ancestors: false).should eq "konsole"
    end
    with_environment(marks: {"VTE_VERSION" => "7200"}) do
      Crysterm::Terminal.current_emulator(ancestors: false).should eq "gnome-terminal"
    end
    with_environment do
      Crysterm::Terminal.current_emulator(ancestors: false).should be_nil
    end
  end

  it "knows the emulators by process name, cut to Linux's 15 characters too" do
    Crysterm::Terminal.emulator_process_name("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal").should eq "terminal.app"
    Crysterm::Terminal.emulator_process_name("gnome-terminal-").should eq "gnome-terminal"
    Crysterm::Terminal.emulator_process_name("kitty").should eq "kitty"
    Crysterm::Terminal.emulator_process_name("zsh").should be_nil
    Crysterm::Terminal.emulator_process_name("steam").should be_nil # not `st`
  end
end

describe "Terminal.graphical?" do
  it "is true inside a multiplexer or under a display, and false on a bare console" do
    with_environment(tmux: "/tmp/tmux-1000/default,1,0") do
      Crysterm::Terminal.graphical?(ancestors: false).should be_true
    end
    with_environment(display: ":0") do
      Crysterm::Terminal.graphical?(ancestors: false).should be_true
    end
    with_environment(wayland_display: "wayland-0") do
      Crysterm::Terminal.graphical?(ancestors: false).should be_true
    end
    with_environment do
      Crysterm::Terminal.graphical?(ancestors: false).should be_false
    end
  end

  {% if flag?(:darwin) %}
    it "takes a terminal emulator for a GUI session on macOS" do
      with_environment(term_program: "Apple_Terminal") do
        Crysterm::Terminal.graphical?(ancestors: false).should be_true
      end
    end
  {% end %}
end

describe "Terminal.resolve_launcher" do
  it "prefers the emulator the program runs in over the registry's order" do
    with_environment(tmux: "/tmp/tmux-1000/default,1,0") do
      if Process.find_executable("tmux")
        Crysterm::Terminal.resolve_launcher(nil).try(&.name).should eq "tmux"
      end
    end
  end

  {% if flag?(:darwin) %}
    it "has Terminal.app on macOS, driven through osascript" do
      launcher = Crysterm::Terminal::LAUNCHERS.find! { |l| l.name == "terminal.app" }
      launcher.available?.should be_true
      launcher.argv_for(["/bin/true"], 80, 24, nil).should be_nil # a custom spawner, not an argv
    end

    it "types the helper command, exec'ed and shell-quoted, into the new window's shell" do
      inner = ["env", "CRYSTERM_WINDOW_HELPER=/tmp/a b.sock", "/Users/me/My Apps/md", "it's \"quoted\""]
      # Through the shell, each word quoted and the helper `exec`ed in the
      # shell's place; then through AppleScript, the shell line as one string
      # literal with its quotes and backslashes escaped.
      literal = %q("exec env 'CRYSTERM_WINDOW_HELPER=/tmp/a b.sock' '/Users/me/My Apps/md' 'it'\"'\"'s \"quoted\"'")

      terminal = Crysterm::Terminal.terminal_app_script(inner, 100, 30, "md — notes")
      terminal.should contain "set t to do script #{literal}\n"
      terminal.should contain "set custom title of t to \"md — notes\"\n"
      terminal.should contain "set number of columns of w to 100\n"
      terminal.should contain "set number of rows of w to 30\n"

      # iTerm2 runs a window's `command` itself, with no shell for the
      # `exec`, so the line is typed into the session's shell instead.
      iterm = Crysterm::Terminal.iterm2_script(inner, 100, 30, nil)
      iterm.should contain "create window with default profile)\n"
      iterm.should_not contain "command "
      iterm.should contain "write text #{literal}\n"
      iterm.should_not contain "set name to"
      iterm.should contain "set columns to 100\n"
    end
  {% end %}
end
