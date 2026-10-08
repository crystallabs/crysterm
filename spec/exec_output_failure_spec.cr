require "./spec_helper"

# A genuine output failure must end the loop driving the window. The render
# fiber used to re-raise its `IO::Error`, which only killed that fiber:
# `Application#exec` stayed blocked on its quit channel (returning normally
# once something else quit it) and nothing restored the terminal. Whether the
# error escaped `exec` depended on which fiber wrote first after the output
# started failing.

# Output that writes normally until `#failing?` is set, then raises on every
# write.
private class ExecFailingOutput < IO::Memory
  property? failing = false

  def write(slice : Bytes) : Nil
    raise IO::Error.new "output failed" if failing?
    super
  end
end

private def exec_failure_window(output)
  Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: 40, height: 10, default_quit_keys: false)
end

# Runs *block* (an `exec` call) on its own fiber and returns a channel that
# receives its result or the exception it raised.
private def exec_failure_run(&block : -> Int32?)
  done = Channel((Int32 | Exception)?).new(1)
  spawn do
    done.send block.call
  rescue ex
    done.send ex
  end
  done
end

private def exec_failure_result(done)
  select
  when result = done.receive
    result
  when timeout(2.seconds)
    fail "the exec loop did not end after its output failed"
  end
end

describe "Application#exec when the output fails" do
  it "raises a render fiber's output failure and tears the window down" do
    output = ExecFailingOutput.new
    s = exec_failure_window output
    app = Crysterm::Application.new
    done = exec_failure_run { app.exec s }
    # Let `exec` finish its setup and park on the quit channel, so the next
    # write happens on the render fiber.
    sleep 100.milliseconds

    output.failing = true
    Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3, content: "changed"
    s.update

    result = exec_failure_result done
    result.should be_a IO::Error
    result.as(IO::Error).message.should eq "output failed"
    s.destroyed?.should be_true
  end

  it "raises when the output already fails as exec starts" do
    output = ExecFailingOutput.new
    s = exec_failure_window output
    Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3, content: "first"
    # Let the frame queued since construction paint while the output still
    # works, as when `exec` runs straight after building the window.
    sleep 50.milliseconds
    output.failing = true
    app = Crysterm::Application.new

    result = exec_failure_result exec_failure_run { app.exec s }
    result.should be_a IO::Error
    s.destroyed?.should be_true
  end

  it "can run another window after an output failure" do
    output = ExecFailingOutput.new
    s = exec_failure_window output
    Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3, content: "first"
    # Let the frame queued since construction paint while the output still
    # works, as when `exec` runs straight after building the window.
    sleep 50.milliseconds
    output.failing = true
    app = Crysterm::Application.new
    exec_failure_result(exec_failure_run { app.exec s }).should be_a IO::Error

    s2 = exec_failure_window IO::Memory.new
    done = exec_failure_run { app.exec s2 }
    sleep 50.milliseconds
    app.quit 3
    exec_failure_result(done).should eq 3
  end
end

describe "Application.exec_all when an output fails" do
  it "tears every window down and raises the failure" do
    output = ExecFailingOutput.new
    a = exec_failure_window output
    b = exec_failure_window IO::Memory.new
    done = exec_failure_run { Crysterm::Application.exec_all [a, b] }
    sleep 100.milliseconds

    output.failing = true
    Crysterm::Widget::Box.new parent: a, top: 0, left: 0, width: 10, height: 3, content: "changed"
    a.update

    exec_failure_result(done).should be_a IO::Error
    a.destroyed?.should be_true
    b.destroyed?.should be_true
  end
end
