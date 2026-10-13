require "./spec_helper"

# A window joining a running `Application#exec` loop by `#add` (as `Window#start_input`
# and a revived window do) is watched for an output failure as a `#show`n one is.

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

private def ended_with(status)
  select
  when s = status.receive
    s
  when timeout(2.seconds)
    fail "the loop did not end"
  end
end

describe "Application#exec watching for output failures" do
  it "watches a window that joins the running loop by #add, as one #show joins it" do
    app = Crysterm::Application.new
    first = headless_window
    added = headless_window
    begin
      status = exec_in_fiber app, first
      app.add added
      added.handlers(Crysterm::Event::OutputFailed).size.should eq 1
      app.show added
      added.handlers(Crysterm::Event::OutputFailed).size.should eq 1

      app.quit 0
      ended_with(status).should eq 0
      added.handlers(Crysterm::Event::OutputFailed).size.should eq 0
    ensure
      first.destroy
      added.destroy
    end
  end

  it "leaves no watch behind when exec returns from a headless capture" do
    app = Crysterm::Application.new
    window = headless_window
    path = File.tempname("capture", ".txt")
    prev = Crysterm::Config.window_dump
    begin
      Crysterm::Config.window_dump = path
      app.exec(window).should eq 0
      window.handlers(Crysterm::Event::OutputFailed).size.should eq 0
    ensure
      Crysterm::Config.window_dump = prev
      File.delete? path
      window.destroy
    end
  end
end
