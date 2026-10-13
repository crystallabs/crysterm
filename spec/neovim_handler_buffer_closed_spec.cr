require "./spec_helper"

# A widget's buffer closed in Neovim (`:bwipeout`, `:bdelete`) no longer
# reports its lines: the handler lets go of the widget and says so with
# `Event::ViDetached`, so an application can turn its Vi mode off, where it
# kept a handler whose edits reached nothing, and later detached it
# without a word on the first call Neovim answered with an error.

private def nvb_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10, default_quit_keys: false)
end

describe Crysterm::Neovim::Handler do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  {"bwipeout!", "bdelete!"}.each do |cmd|
    it "detaches with ViDetached on :#{cmd}" do
      window = nvb_window
      w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
      w.value = "abc"
      h = Crysterm::Neovim::Handler.new
      reasons = [] of String
      exits = 0
      h.on(Crysterm::Event::ViDetached) { |e| reasons << e.reason }
      h.on(Crysterm::Event::ProcessExited) { exits += 1 }
      h.attach(w).should be_true
      h.input ":#{cmd}<CR>"
      wait_until { !h.attached? }
      reasons.size.should eq 1
      exits.should eq 0
      h.client.should be_nil
      # The widget edits on its own again.
      w.value = "xyz"
      w.value.should eq "xyz"
    ensure
      h.try &.detach
      window.try &.destroy
    end
  end

  it "lets the handlers sharing a Neovim go on after one's buffer is wiped" do
    window = nvb_window
    a = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 4
    b = Crysterm::Widget::PlainTextEdit.new parent: window, top: 5, width: 40, height: 4
    a.value = "abc"
    b.value = "xyz"
    client = Crysterm::Neovim::Client.new(args: Crysterm::Neovim::Handler.default_args.dup)
    ha = Crysterm::Neovim::Handler.new client
    hb = Crysterm::Neovim::Handler.new client
    detached = [] of Crysterm::Neovim::Handler
    ha.on(Crysterm::Event::ViDetached) { detached << ha }
    hb.on(Crysterm::Event::ViDetached) { detached << hb }
    ha.attach(a).should be_true
    hb.attach(b).should be_true
    hb.input ":bwipeout!<CR>"
    wait_until { !hb.attached? }
    detached.should eq [hb]
    client.@shown_buffer.should be_nil
    ha.attached?.should be_true
    ha.input "0x"
    a.value.should eq "bc"
    ha.detach
    client.@shown_buffer.should be_nil
  ensure
    client.try &.close
    window.try &.destroy
  end
end
