require "./spec_helper"

# Neovim reports some commands to `nvim_buf_attach` line by line (an undo
# of `:%s`, `:g`). Each line went to the widget as an edit of its own — an
# undo step of the widget each, and on a long document minutes of work (the
# undo of a `:%s` over 10,000 lines took 5 s, over 100,000 several minutes).
# The changes Neovim makes in one go reach the widget as one edit.

describe Crysterm::Neovim::Handler do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  it "mirrors a change Neovim reports line by line as one edit" do
    window = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 10, default_quit_keys: false)
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    text = (1..2000).map { |i| "line #{i} ü" }.join("\n") + "\n"
    w.value = text
    h = Crysterm::Neovim::Handler.new
    h.attach(w).should be_true
    h.input ":%s/line/LINE/<CR>"
    w.value.should eq text.gsub("line", "LINE")
    edits = 0
    w.on(Crysterm::Event::TextChanged) { edits += 1 }
    started = Time.instant
    h.input "u"
    w.value.should eq text
    edits.should eq 1
    (Time.instant - started).should be < 1.second
    h.input ":g/5/d<CR>"
    w.value.should eq text.lines.reject(&.includes?('5')).map { |l| l + "\n" }.join
    h.input "u"
    w.value.should eq text
    h.input "<C-r>"
    w.value.should eq text.lines.reject(&.includes?('5')).map { |l| l + "\n" }.join
  ensure
    h.try &.detach
    window.try &.destroy
  end
end
