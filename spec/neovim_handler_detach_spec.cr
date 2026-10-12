require "./spec_helper"

# `Neovim::Handler#detach` ends the handler's own Neovim without reporting
# it as a Neovim that ended under the widget: `Event::ProcessExited` is for
# a Neovim that exits by itself (`:qa!` sent to it, a crash), not for the
# one the application let go of.

private def nvd_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10, default_quit_keys: false)
end

describe Crysterm::Neovim::Handler do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  it "emits no ProcessExited when detached, and does when Neovim exits by itself" do
    window = nvd_window
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "abc"
    h = Crysterm::Neovim::Handler.new
    exits = 0
    h.on(Crysterm::Event::ProcessExited) { exits += 1 }

    h.attach(w).should be_true
    client = h.client.not_nil!
    h.detach
    client.running?.should be_false
    sleep 50.milliseconds
    exits.should eq 0

    # Attached again: a Neovim that quits on its own is still reported.
    h.attach(w).should be_true
    h.client.not_nil!.notify "nvim_command", "qall!"
    wait_until { exits == 1 }
    h.attached?.should be_false
    window.destroy
  end
end
