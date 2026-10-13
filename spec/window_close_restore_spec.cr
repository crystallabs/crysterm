require "./spec_helper"

# Closing a window hands its terminal back as quitting does, and nothing the
# rest of the teardown does reaches the terminal afterwards. `Window#close`
# disconnects (restoring the terminal) before `#destroy` takes focus away;
# a text input in its reading mode then hid the cursor the restore had just
# shown (`\e[?25l` after the return to the normal buffer), so the shell was
# left without a cursor after Window → Close on the last window.

private def close_restore_window(output : IO) : {Crysterm::Window, Crysterm::Widget::TextEdit}
  w = Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: 40, height: 10, default_quit_keys: false)
  # A real terminal's cursor, as md's editor has: the hardware path is the
  # one that writes show/hide sequences.
  w.screen.hardware_cursor = true
  editor = Crysterm::Widget::TextEdit.new parent: w, width: 30, height: 5
  editor.focus
  editor.read_input
  w.show_cursor
  w.repaint
  {w, editor}
end

# What *output* received from *mark* on.
private def close_restore_tail(output : IO::Memory, mark : Int32) : String
  output.to_s[mark..]
end

# Asserts that *tail* ends the way a terminal handed back ends: the cursor
# shown and the alternate screen left, and no cursor hide after the show.
private def close_restore_check(tail : String) : Nil
  tail.should contain "\e[?1049l"
  shown = tail.rindex("\e[?25h").should_not be_nil
  if hidden = tail.rindex("\e[?25l")
    hidden.should be < shown
  end
  tail[tail.rindex!("\e[?1049l")..].should_not contain "\e[?25l"
end

describe "Window#close restores the terminal" do
  it "leaves the cursor shown when a reading text input loses focus in the teardown" do
    output = IO::Memory.new
    w, _ = close_restore_window output
    mark = output.to_s.size

    w.close.should be_true
    close_restore_check close_restore_tail(output, mark)
  end

  it "writes the same restore as a destroy (the quit path)" do
    closed = IO::Memory.new
    w1, _ = close_restore_window closed
    mark1 = closed.to_s.size
    w1.close

    destroyed = IO::Memory.new
    w2, _ = close_restore_window destroyed
    mark2 = destroyed.to_s.size
    w2.destroy

    close_restore_tail(closed, mark1).should eq close_restore_tail(destroyed, mark2)
  end

  it "ends a running exec with the terminal restored when the only window closes" do
    output = IO::Memory.new
    w, _ = close_restore_window output
    app = Crysterm::Application.new
    done = Channel(Int32 | Exception).new(1)
    spawn do
      done.send app.exec(w)
    rescue ex
      done.send ex
    end
    # Let `exec` finish its setup and park on its quit channel.
    sleep 100.milliseconds
    mark = output.to_s.size

    w.try_close.should be_true
    select
    when result = done.receive
      result.should eq 0
    when timeout(2.seconds)
      fail "exec did not end when its only window closed"
    end
    close_restore_check close_restore_tail(output, mark)
  end

  it "keeps the cursor writes of a closed window off the terminal while it is disconnected" do
    output = IO::Memory.new
    w, _ = close_restore_window output
    w.disconnect
    mark = output.to_s.size

    w.hide_cursor
    w.show_cursor
    w.reset_cursor
    output.to_s.size.should eq mark
    w.destroy
  end
end
