require "./spec_helper"

# A widget's text set by the application while a `Neovim::Handler` is
# attached. `set_plain_text` resets the document (its undo stack cleared,
# as when an application opens another file in the editor) but reached
# Neovim as an ordinary change, so `u` brought back the text from before;
# and the text of a read-only widget, whose buffer is not 'modifiable',
# failed to reach Neovim at all, detaching the handler with a Lua error.

private def nvr_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10, default_quit_keys: false)
end

describe Crysterm::Neovim::Handler do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  it "clears Neovim's undo history when the widget's document is reset" do
    window = nvr_window
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "one\ntwo\n"
    h = Crysterm::Neovim::Handler.new
    h.attach(w).should be_true
    h.input "gg0x"
    w.value.should eq "ne\ntwo\n"
    w.plain_text = "other\nfile\n"
    h.sync
    h.input "u"
    w.value.should eq "other\nfile\n"
    h.input "u"
    w.value.should eq "other\nfile\n"
    h.input "gg0xu"
    w.value.should eq "other\nfile\n"
    h.client.not_nil!.request("nvim_exec_lua", "return vim.bo[...].modified", [h.buffer]).as_bool.should be_false
  ensure
    h.try &.detach
    window.try &.destroy
  end

  it "keeps Neovim's undo history for an ordinary outside change" do
    window = nvr_window
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "one\n"
    h = Crysterm::Neovim::Handler.new
    h.attach(w).should be_true
    w.text_cursor = Crysterm::TextCursor.new(w.document, 0)
    w.text_cursor.insert_text "zero "
    h.sync
    w.value.should eq "zero one\n"
    h.input "u"
    w.value.should eq "one\n"
  ensure
    h.try &.detach
    window.try &.destroy
  end

  it "takes the text the application sets on a read-only widget" do
    window = nvr_window
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "one\ntwo\n"
    w.read_only = true
    h = Crysterm::Neovim::Handler.new
    detached = [] of String
    h.on(Crysterm::Event::ViDetached) { |e| detached << e.reason }
    h.attach(w).should be_true
    w.value = "three\nfour\n"
    h.sync
    h.attached?.should be_true
    detached.should be_empty
    h.input "ggjx"
    w.value.should eq "three\nfour\n"
    h.client.not_nil!.request("nvim_buf_get_lines", h.buffer, 0, -1, true).as_a.map(&.to_s).should eq ["three", "four"]
    h.client.not_nil!.request("nvim_exec_lua", "return vim.bo[...].modifiable", [h.buffer]).as_bool.should be_false
  ensure
    h.try &.detach
    window.try &.destroy
  end
end
