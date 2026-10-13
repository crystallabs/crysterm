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

  it "types nothing into a shared Neovim once detached" do
    window = nvd_window
    a = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 4
    b = Crysterm::Widget::PlainTextEdit.new parent: window, top: 5, width: 40, height: 4
    a.value = "abc"
    b.value = "xyz"
    client = Crysterm::Neovim::Client.new(args: Crysterm::Neovim::Handler.default_args.dup)
    ha = Crysterm::Neovim::Handler.new client
    hb = Crysterm::Neovim::Handler.new client
    ha.attach(a).should be_true
    hb.attach(b).should be_true
    hb.detach
    # The window shows the other handler's buffer now; keys sent through
    # the detached handler go nowhere.
    hb.input "0x"
    ha.sync
    a.value.should eq "abc"
    ha.detach
  ensure
    client.try &.close
    window.try &.destroy
  end

  it "leaves no exit block on a shared Neovim it detached from" do
    window = nvd_window
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    client = Crysterm::Neovim::Client.new(args: Crysterm::Neovim::Handler.default_args.dup)
    before = client.@exit_handlers.size
    h = Crysterm::Neovim::Handler.new client
    3.times do
      h.attach(w).should be_true
      h.detach
    end
    client.@exit_handlers.size.should eq before
    client.running?.should be_true
  ensure
    client.try &.close
    window.try &.destroy
  end
end
