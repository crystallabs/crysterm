require "./spec_helper"

include Crysterm

# `Window#request_close` (Qt's `closeEvent`) asks the window's
# `Event::CloseRequest` handlers before the default quit keys quit: a
# handler that `#ignore`s keeps the app running, e.g. over unsaved changes.
# `#quit`/`#close`/`#destroy` stay unconditional and never ask.

private def close_request_window : Window
  Crysterm::Window.new input: IO::Memory.new, output: IO::Memory.new, width: 40, height: 10
end

describe "Window#request_close" do
  it "returns true with no handlers" do
    w = close_request_window
    begin
      w.request_close.should be_true
    ensure
      w.destroy
    end
  end

  it "returns false when a handler ignores, true when one merely looks" do
    w = close_request_window
    begin
      asked = 0
      w.on(Event::CloseRequest) { asked += 1 }
      w.request_close.should be_true
      asked.should eq 1

      modified = true
      w.on(Event::CloseRequest) { |e| e.ignore if modified }
      w.request_close.should be_false
      modified = false
      w.request_close.should be_true
      asked.should eq 3
    ensure
      w.destroy
    end
  end

  it "accept after ignore lets the close go ahead again" do
    e = Event::CloseRequest.new
    e.accepted?.should be_true
    e.ignore
    e.accepted?.should be_false
    e.accept
    e.accepted?.should be_true
  end
end

describe "Application#route_input asks the window before quitting" do
  it "does not quit on the quit gesture when a handler ignores" do
    app = Application.new
    w = Crysterm::Window.new input: IO::Memory.new, output: IO::Memory.new,
      width: 40, height: 10, default_quit_keys: true
    app.add w
    begin
      asked = false
      w.on(Event::CloseRequest) do |e|
        asked = true
        e.ignore
      end
      # A quit here would `exit` the process (no exec loop to unwind to):
      # reaching the assertions proves the veto held.
      app.route_input w.screen, ::Tput::InputEvent.new('q')
      asked.should be_true
      w.destroyed?.should be_false
    ensure
      w.destroy
    end
  end

  it "quits on the quit gesture when no handler ignores" do
    app = Application.new
    w = Crysterm::Window.new input: IO::Memory.new, output: IO::Memory.new,
      width: 40, height: 10, default_quit_keys: true
    begin
      asked = false
      w.on(Event::CloseRequest) { asked = true }
      status = Channel(Int32).new(1)
      spawn { status.send app.exec(w) }
      sleep 20.milliseconds # let exec start listening
      app.route_input w.screen, ::Tput::InputEvent.new('q')
      select
      when s = status.receive
        s.should eq 0
      when timeout(2.seconds)
        fail "the app did not quit"
      end
      asked.should be_true
      w.destroyed?.should be_true
    ensure
      w.destroy
    end
  end
end

describe "Application.exec_all asks the window before closing its windows" do
  it "keeps the windows when a handler ignores, closes them when none does" do
    w = Crysterm::Window.new input: IO::Memory.new, output: IO::Memory.new,
      width: 40, height: 10, default_quit_keys: true
    begin
      modified = true
      w.on(Event::CloseRequest) { |e| e.ignore if modified }
      done = Channel(Nil).new(1)
      spawn do
        Application.exec_all [w]
        done.send nil
      end
      sleep 20.milliseconds # let exec_all install its quit-key handler

      w.emit Event::KeyPress.new 'q'
      sleep 30.milliseconds
      w.destroyed?.should be_false

      modified = false
      w.emit Event::KeyPress.new 'q'
      select
      when done.receive
      when timeout(2.seconds)
        fail "exec_all did not return"
      end
      w.destroyed?.should be_true
    ensure
      w.destroy
    end
  end
end
