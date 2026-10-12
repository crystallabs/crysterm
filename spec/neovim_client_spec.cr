require "./spec_helper"

private NVIM_ARGS = ["--headless", "--clean", "-n"]

private def with_nvim(&)
  nvim = Crysterm::Neovim::Client.new args: NVIM_ARGS
  begin
    yield nvim
  ensure
    nvim.close
  end
end

describe Crysterm::Neovim::Client do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  it "returns a request's result" do
    with_nvim do |nvim|
      nvim.request("nvim_eval", "1+2").as_i.should eq 3
      nvim.request("nvim_eval", "[1, 'a', {'k': v:true}]").as_a.should eq [1, "a", {"k" => true}]
    end
  end

  it "reads handles as their number" do
    with_nvim do |nvim|
      nvim.request("nvim_get_current_buf").as_i64.should eq 1
      nvim.request("nvim_buf_line_count", 1_i64).as_i.should eq 1
    end
  end

  it "raises Neovim::Error on an error answer, and goes on" do
    with_nvim do |nvim|
      ex = expect_raises(Crysterm::Neovim::Error) { nvim.request("nvim_eval", "no_such_function()") }
      ex.message.not_nil!.should contain "no_such_function"
      ex.type.should_not be_nil
      expect_raises(Crysterm::Neovim::Error) { nvim.request("no_such_method") }
      nvim.request("nvim_eval", "2*3").as_i.should eq 6
    end
  end

  it "answers concurrent requests from several fibers" do
    with_nvim do |nvim|
      results = Channel({Int32, Int32}).new 10
      10.times do |i|
        spawn { results.send({i, nvim.request("nvim_eval", "#{i}*#{i}").as_i}) }
      end
      10.times do
        i, sq = results.receive
        sq.should eq i * i
      end
    end
  end

  it "hands notifications to on_notification, in order" do
    with_nvim do |nvim|
      got = [] of {String, Array(MessagePack::Type)}
      nvim.on_notification { |method, params| got << {method, params} }
      chan = nvim.channel_id
      nvim.request("nvim_command", "call rpcnotify(#{chan}, 'first', 1, 'x')")
      nvim.notify("nvim_command", "call rpcnotify(#{chan}, 'second')")
      wait_until { got.size >= 2 }
      got[0][0].should eq "first"
      got[0][1].size.should eq 2
      got[0][1][1].should eq "x"
      got[1][0].should eq "second"
    end
  end

  it "lets a notification handler make requests" do
    with_nvim do |nvim|
      answer = nil
      nvim.on_notification { |_, _| answer = nvim.request("nvim_eval", "40+2").as_i }
      nvim.notify("nvim_command", "call rpcnotify(#{nvim.channel_id}, 'ping')")
      wait_until { answer }
      answer.should eq 42
    end
  end

  it "answers Neovim's requests through on_request, and with an error without one" do
    with_nvim do |nvim|
      chan = nvim.channel_id
      expect_raises(Crysterm::Neovim::Error, /no handler/) do
        nvim.request("nvim_eval", "rpcrequest(#{chan}, 'ask', 5)")
      end
      nvim.on_request do |method, params|
        method.should eq "ask"
        (params[0].as(Int).to_i64 * 10).as(Crysterm::Neovim::Client::Value)
      end
      nvim.request("nvim_eval", "rpcrequest(#{chan}, 'ask', 5)").as_i.should eq 50
    end
  end

  it "gives up on a request after its timeout" do
    with_nvim do |nvim|
      # Neovim busy (blocked in a sleep) answers nothing meanwhile.
      spawn { nvim.request("nvim_exec_lua", "vim.uv.sleep(400)", [] of String) rescue nil }
      sleep 20.milliseconds
      expect_raises(Crysterm::Neovim::Error, /within/) do
        nvim.request("nvim_eval", "1", timeout: 100.milliseconds)
      end
      # The late answer is dropped, and the channel goes on.
      nvim.request("nvim_eval", "7").as_i.should eq 7
    end
  end

  it "closes: reaps the process, runs on_exit, and is idempotent" do
    nvim = Crysterm::Neovim::Client.new args: NVIM_ARGS
    exits = [] of Int32?
    nvim.on_exit { |code| exits << code }
    nvim.running?.should be_true
    pid = nvim.pid
    nvim.close.should eq 0
    nvim.running?.should be_false
    wait_until { exits.size == 1 }
    exits.should eq [0] of Int32?
    nvim.process.exists?.should be_false
    Process.exists?(pid).should be_false
    nvim.close.should eq 0
    expect_raises(Crysterm::Neovim::Error) { nvim.request("nvim_eval", "1") }
    expect_raises(Crysterm::Neovim::Error) { nvim.notify("nvim_eval", "1") }
    # A block added after the exit runs at once.
    late = nil.as(Int32?)
    nvim.on_exit { |code| late = code }
    late.should eq 0
  end

  it "notices Neovim quitting on its own, failing the request in flight" do
    nvim = Crysterm::Neovim::Client.new args: NVIM_ARGS
    exited = Channel(Int32?).new 1
    nvim.on_exit { |code| exited.send code }
    expect_raises(Crysterm::Neovim::Error) { nvim.request("nvim_command", "cquit 3") }
    exited.receive.should eq 3
    nvim.running?.should be_false
    nvim.exit_code.should eq 3
  end

  it "raises Neovim::Error for an executable that is not there" do
    expect_raises(Crysterm::Neovim::Error, /not found/) do
      Crysterm::Neovim::Client.new executable: "no-such-nvim-executable"
    end
  end
end
