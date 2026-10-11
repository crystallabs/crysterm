require "./spec_helper"

include Crysterm

# `Application::Clipboard#mode`: where a copy goes and where a paste comes
# from — the terminal (OSC 52), a system command, or the in-process mirror
# alone. The command runner is replaced to observe the commands; headless
# harness like `bugs13_core_application_spec.cr`.

private def ctl(k : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', k
end

# A runner that records every command and its input and answers with
# *output* (nil: the command failed).
private class RecordingRunner
  getter calls = [] of {Array(String), String}
  property output : String?

  def initialize(@output = "")
  end

  def to_proc : Application::Clipboard::CommandRunner
    ->(argv : Array(String), input : String) do
      @calls << {argv, input}
      @output
    end
  end
end

private def with_clipboard(&)
  app = Application.new
  w = headless_screen(40, 10)
  app.add w
  clip = app.clipboard
  clip.copy_command = ["copy-cmd", "--in"]
  clip.paste_command = ["paste-cmd", "--out"]
  begin
    yield clip, w, w.output.as(IO::Memory)
  ensure
    w.destroy
  end
end

describe Application::Clipboard do
  it "writes OSC 52 to the terminal by default, and runs nothing" do
    with_clipboard do |clip, _, output|
      runner = RecordingRunner.new
      clip.command_runner = runner.to_proc
      clip.mode.should eq Application::Clipboard::Mode::Terminal
      output.clear
      clip.copy "hello"
      output.to_s.should contain Base64.strict_encode("hello")
      runner.calls.should be_empty
      clip.text.should eq "hello"
      clip.error.should be_nil
    end
  end

  it "pipes a copy to the copy command in Command mode, and nothing to the terminal" do
    with_clipboard do |clip, _, output|
      runner = RecordingRunner.new
      clip.command_runner = runner.to_proc
      clip.mode = :command
      output.clear
      clip.copy "hello"
      runner.calls.should eq [{["copy-cmd", "--in"], "hello"}]
      output.size.should eq 0
      clip.error.should be_nil
    end
  end

  it "reads a paste from the paste command in Command mode, dropping a stale fragment" do
    with_clipboard do |clip, w, _|
      runner = RecordingRunner.new
      clip.command_runner = runner.to_proc
      clip.mode = :command
      te = Widget::TextEdit.new parent: w, left: 0, top: 0, width: 30, height: 5, content: "rich"
      w.repaint
      te.cursor_pos = 4
      te.selection_anchor = 0
      te._listener ctl(::Tput::Key::CtrlC)
      clip.fragment.should_not be_nil

      # The system still holds our own copy: the fragment stays.
      runner.output = "rich"
      clip.text.should eq "rich"
      clip.fragment.should_not be_nil
      # Something else was copied outside: the mirror follows, the fragment goes.
      runner.output = "from outside"
      clip.text.should eq "from outside"
      clip.fragment.should be_nil
      runner.calls.last.should eq({["paste-cmd", "--out"], ""})
    end
  end

  it "keeps the text in the mirror and names the failure when the command fails or is missing" do
    with_clipboard do |clip, _, _|
      runner = RecordingRunner.new(nil)
      clip.command_runner = runner.to_proc
      clip.mode = :command
      clip.copy "kept"
      clip.error.should eq "copy-cmd failed"
      clip.copy_command = nil
      clip.copy "still kept"
      clip.error.should eq "no clipboard command found"
      # A paste with no command falls back to the mirror, with the same note.
      clip.paste_command = nil
      clip.text.should eq "still kept"
      clip.error.should eq "no clipboard command found"
      clip.mode = :internal
      clip.copy "fine"
      clip.error.should be_nil
    end
  end

  it "keeps a copy in-process in Internal mode" do
    with_clipboard do |clip, _, output|
      runner = RecordingRunner.new
      clip.command_runner = runner.to_proc
      clip.mode = :internal
      output.clear
      clip.copy "private"
      output.size.should eq 0
      runner.calls.should be_empty
      clip.text.should eq "private"
    end
  end

  it "answers a request at once outside Terminal mode, as a ClipboardChanged" do
    with_clipboard do |clip, w, output|
      runner = RecordingRunner.new("from command")
      clip.command_runner = runner.to_proc
      heard = [] of String
      w.on(Crysterm::Event::ClipboardChanged) { |e| heard << e.content }

      output.clear
      clip.request w
      output.size.should be > 0 # the OSC 52 query
      heard.should be_empty

      clip.mode = :command
      clip.request w
      heard.should eq ["from command"]
      clip.mode = :internal
      clip.copy "mine"
      clip.request w
      heard.should eq ["from command", "mine"]
    end
  end

  it "detects a copy command on the PATH, with its display when it needs one" do
    copy, paste = Application::Clipboard.detect_commands
    if Process.find_executable("pbcopy")
      copy.should eq ["pbcopy"]
      paste.should eq ["pbpaste"]
    elsif copy
      Process.find_executable(copy[0]).should_not be_nil
      paste.should_not be_nil
    end
  end

  it "runs a real command through the default runner" do
    Application::Clipboard.run_command(["cat"], "round trip").should eq "round trip"
    Application::Clipboard.run_command(["false"], "").should be_nil
    Application::Clipboard.run_command(["no-such-command-for-crysterm"], "").should be_nil
  end
end

describe "TextEditing#copy, #cut, #paste" do
  it "copy and cut answer whether there was a selection; paste inserts" do
    s = headless_screen(80, 24)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8, content: "hello world"
    s.repaint
    clip = (s.application || Application.global).clipboard
    clip.mode = :internal
    te.copy.should be_false
    te.cursor_pos = 5
    te.selection_anchor = 0
    te.copy.should be_true
    clip.text.should eq "hello"
    te.cut.should be_true
    te.value.should eq " world"
    te.cursor_pos = 6
    te.paste
    te.value.should eq " worldhello"
    te.read_only = true
    te.paste
    te.value.should eq " worldhello"
    s.destroy
  end

  it "leaves a selection-less Ctrl-C to the application" do
    s = headless_screen(80, 24)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8, content: "hello"
    s.repaint
    e = ctl(::Tput::Key::CtrlC)
    te._listener e
    e.accepted?.should be_false
    te.cursor_pos = 5
    te.selection_anchor = 0
    e = ctl(::Tput::Key::CtrlC)
    te._listener e
    e.accepted?.should be_true
    s.destroy
  end
end
