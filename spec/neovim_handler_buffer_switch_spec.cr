require "./spec_helper"

# Another buffer put in Neovim's window from Neovim (`:enew`, `:e FILE`,
# `:b N`), or another window entered (`:split`, `:new`), took the keys
# meant for the widget's buffer, while the handler still took its own for
# the one shown: the widget stopped mirroring what the keys did. The
# window and the widget's buffer come back, with an error.

private def nvs_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10, default_quit_keys: false)
end

describe Crysterm::Neovim::Handler do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  path = File.tempname("crysterm-nvs", ".txt")

  {"enew", "e #{path}", "b 1", "bnext", "split", "vnew"}.each do |cmd|
    it "keeps the widget's buffer in the window on :#{cmd.split.first}" do
      File.write path, "other\n"
      window = nvs_window
      w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
      w.value = "abc"
      h = Crysterm::Neovim::Handler.new
      messages = [] of {String?, String}
      detached = 0
      h.on(Crysterm::Event::ViMessageChanged) { |e| messages << {e.text, e.kind} }
      h.on(Crysterm::Event::ViDetached) { detached += 1 }
      h.attach(w).should be_true
      h.input ":#{cmd}<CR>"
      h.input "0x"
      w.value.should eq "bc"
      h.input "Ad<Esc>"
      w.value.should eq "bcd"
      h.attached?.should be_true
      detached.should eq 0
      wait_until { messages.any? { |m| m[0].try &.includes?("widget's own buffer") } }
      File.read(path).should eq "other\n"
    ensure
      h.try &.detach
      window.try &.destroy
      File.delete?(path)
    end
  end

  it "keeps each sharing handler's buffer its own" do
    window = nvs_window
    a = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 4
    b = Crysterm::Widget::PlainTextEdit.new parent: window, top: 5, width: 40, height: 4
    a.value = "abc"
    b.value = "xyz"
    client = Crysterm::Neovim::Client.new(args: Crysterm::Neovim::Handler.default_args.dup)
    ha = Crysterm::Neovim::Handler.new client
    hb = Crysterm::Neovim::Handler.new client
    ha.attach(a).should be_true
    hb.attach(b).should be_true
    # B's buffer is shown; A's put there from Neovim goes back.
    hb.input ":b #{ha.buffer}<CR>"
    hb.input "0x"
    b.value.should eq "yz"
    a.value.should eq "abc"
    ha.input "0x"
    a.value.should eq "bc"
    b.value.should eq "yz"
    ha.detach
    hb.detach
  ensure
    client.try &.close
    window.try &.destroy
  end
end
