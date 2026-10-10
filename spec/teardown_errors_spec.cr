require "./spec_helper"

include Crysterm

# Errors raised while an app quits, or by a handler on one of the toolkit's
# fibers, used to wedge the process: `Application#quit` latched itself before
# tearing the windows down, so a raise part-way (a widget's `Destroy` handler,
# the focus change a focused widget's removal triggers) left every later
# `quit` a no-op, the window latched as destroyed before its terminal was
# restored (so even the `at_exit` net restored nothing), the render fiber
# stopped and the input fiber alive — a deaf, frozen screen that an external
# kill left in raw mode. The input fiber's own rescue then logged the
# backtrace to standard error, i.e. over the live screen.

private def teardown_window
  Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10, default_quit_keys: false)
end

# Runs *block* (an `exec` call) on its own fiber; the channel receives its
# result or the exception it raised.
private def run_exec(&block : -> Int32)
  done = Channel(Int32 | Exception).new(1)
  spawn do
    done.send block.call
  rescue ex
    done.send ex
  end
  done
end

private def exec_result(done)
  select
  when result = done.receive
    result
  when timeout(2.seconds)
    fail "the exec loop did not end"
  end
end

# Lets an `exec` started on another fiber finish its setup and park on its
# quit channel.
private def settle
  sleep 50.milliseconds
end

private class RaisingPaint < Widget::Box
  def paint(*, with_children = true)
    raise "paint boom"
  end
end

describe "Window#destroy when a widget's teardown raises" do
  it "tears the rest down and restores the connection, then re-raises" do
    s = teardown_window
    a = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 2
    b = Widget::Box.new parent: s, top: 3, left: 0, width: 5, height: 2
    a.on(Event::Destroy) { raise "boom" }

    expect_raises(Exception, "boom") { s.destroy }
    s.destroyed?.should be_true
    s.connected?.should be_false
    a.attached?.should be_false
    b.attached?.should be_false
    s.children.should be_empty
    # Already fully destroyed: a later teardown (the `at_exit` net's) is a
    # quiet no-op.
    s.destroy
  end

  it "re-raises a FocusOut error from the focused widget giving focus up, and rewinds to nobody" do
    # The shape of the original bug was a focus rewind: destroying the
    # focused widget handed focus to a sibling, whose `FocusIn` handler asked
    # the now-detached widget for its geometry. A destroyed widget now gives
    # focus up without a successor (Qt's `clearFocus`), so no `FocusIn` runs
    # during teardown; the handler that can still raise is the focused
    # widget's own `FocusOut`. The error surfaces once the window is fully
    # gone, with every widget detached.
    s = teardown_window
    root = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 8
    a = Widget::Box.new parent: root, top: 0, left: 0, width: 5, height: 2
    b = Widget::Box.new parent: root, top: 3, left: 0, width: 5, height: 2
    a.focus_policy = b.focus_policy = Widget::FocusPolicy::Strong
    b.focus
    a.focus
    a.focused?.should be_true
    rewound = false
    b.on(Event::FocusIn) { rewound = true }
    a.on(Event::FocusOut) { raise "blur boom" }

    expect_raises(Exception, "blur boom") { s.destroy }
    rewound.should be_false
    s.focused.should be_nil
    s.destroyed?.should be_true
    s.connected?.should be_false
    root.attached?.should be_false
    b.attached?.should be_false
    s.children.should be_empty
  end
end

describe "Application#quit when a teardown step raises" do
  it "finishes the teardown, then raises the error from exec" do
    s = teardown_window
    a = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 2
    a.on(Event::Destroy) { raise "boom" }
    app = Application.new
    done = run_exec { app.exec s }
    settle

    app.quit
    result = exec_result done
    result.should be_a Exception
    result.as(Exception).message.should eq "boom"
    s.destroyed?.should be_true
    s.connected?.should be_false
    app.windows.should be_empty

    # The app is usable again: the quit latch was re-armed.
    s2 = teardown_window
    done = run_exec { app.exec s2 }
    settle
    app.quit 3
    exec_result(done).should eq 3
  end

  it "treats a raising AboutToQuit handler the same way" do
    s = teardown_window
    app = Application.new
    app.on(Event::AboutToQuit) { raise "save failed" }
    done = run_exec { app.exec s }
    settle

    app.quit
    result = exec_result done
    result.as(Exception).message.should eq "save failed"
    s.destroyed?.should be_true
  end
end

describe "Application#handler_raised" do
  it "logs the error and goes on when nothing handles it" do
    s = teardown_window
    app = Application.new
    done = run_exec { app.exec s }
    settle

    app.handler_raised RuntimeError.new("handler boom")
    s.destroyed?.should be_false
    app.quit 0
    exec_result(done).should eq 0
  end

  it "continues when a HandlerError handler takes the error" do
    s = teardown_window
    app = Application.new
    seen = [] of Exception
    app.on(Event::HandlerError) { |e| seen << e.error }
    done = run_exec { app.exec s }
    settle

    app.handler_raised RuntimeError.new("handler boom")
    seen.map(&.message).should eq ["handler boom"]
    s.destroyed?.should be_false
    app.quit 0
    exec_result(done).should eq 0
  end

  it "is fatal when the HandlerError handler raises in turn" do
    s = teardown_window
    app = Application.new
    app.on(Event::HandlerError) { raise "reporter boom" }
    done = run_exec { app.exec s }
    settle

    app.handler_raised RuntimeError.new("handler boom")
    exec_result(done).as(Exception).message.should eq "reporter boom"
  end

  it "keeps an error raised while quitting for exec" do
    s = teardown_window
    a = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 2
    app = Application.new
    app.on(Event::HandlerError) { fail "a quit-time error is not for continuing" }
    a.on(Event::Destroy) { app.handler_raised RuntimeError.new("late") }
    done = run_exec { app.exec s }
    settle

    app.quit
    exec_result(done).as(Exception).message.should eq "late"
  end

  it "runs the input fiber's handler errors through the policy" do
    reader, writer = IO.pipe
    begin
      screen = Screen.new(input: reader, output: IO::Memory.new, error: IO::Memory.new, width: 40, height: 10)
      w = Window.new(screen: screen, default_quit_keys: false)
      w.on(Event::KeyPress) { raise "key boom" }
      app = Application.new
      seen = [] of Exception
      app.on(Event::HandlerError) { |e| seen << e.error }
      done = run_exec { app.exec w }
      settle

      writer.write "a".to_slice
      writer.flush
      wait_until { seen.size >= 1 }
      seen.map(&.message).should eq ["key boom"]
      w.destroyed?.should be_false
      app.quit 0
      exec_result(done).should eq 0
    ensure
      writer.close rescue nil
      reader.close rescue nil
    end
  end
end

describe "Application#render_raised" do
  it "quits and raises from exec when painting raises" do
    s = teardown_window
    app = Application.new
    done = run_exec { app.exec s }
    settle

    RaisingPaint.new parent: s, top: 0, left: 0, width: 5, height: 2
    s.update
    result = exec_result done
    result.as(Exception).message.should eq "paint boom"
    s.destroyed?.should be_true
    s.connected?.should be_false
  end
end
