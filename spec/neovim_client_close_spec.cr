require "./spec_helper"

describe Crysterm::Neovim::Client do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  it "ends a Neovim that stopped reading while a write is blocked on its input" do
    nvim = Crysterm::Neovim::Client.new args: ["--headless", "--clean", "-n"]
    nvim.request("nvim_eval", "1").as_i.should eq 1
    Process.signal Signal::STOP, nvim.pid
    # A message larger than the pipe holds parks its writer, which keeps
    # the write lock, while Neovim reads nothing.
    spawn { nvim.notify("nvim_input", "x" * 1_000_000) rescue nil }
    Fiber.yield
    done = Channel(Int32?).new 1
    spawn { done.send nvim.close(grace: 200.milliseconds) }
    select
    when code = done.receive
      code.should be_nil
      nvim.running?.should be_false
    when timeout(5.seconds)
      Process.signal Signal::KILL, nvim.pid rescue nil
      fail "close did not end the stopped Neovim"
    end
  end
end
