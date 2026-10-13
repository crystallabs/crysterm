require "./spec_helper"

# A change of the widget made while Neovim has changes of its own on their
# way (a key Neovim was slower to take than `#sync_timeout`): it was sent as
# lines counted on the handler's stale copy of the buffer, which put it on
# the wrong lines, and Neovim's change then landed on the widget's text in
# the wrong place, leaving the two out of step. A Neovim busy with a loop
# held a call of the handler, and with it the application, for good; and a
# document set on the widget was not followed.

private def nvs_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10, default_quit_keys: false)
end

private def nvs_lines(h)
  h.client.not_nil!.request("nvim_buf_get_lines", h.buffer, 0, -1, true).as_a.map(&.to_s)
end

# Syncs until the widget's text is Neovim's lines (each with its newline).
private def nvs_settle(h, w)
  20.times do
    h.sync
    break if w.value == nvs_lines(h).join { |l| l + "\n" }
    sleep 20.milliseconds
  end
end

# Changes Neovim's buffer behind the handler's back, as a key would: the
# change is reported once Neovim is next idle, after the call returns.
private def nvs_nvim_set(h, first, last, lines : Array(String))
  h.client.not_nil!.request "nvim_buf_set_lines", h.buffer, first, last, false, lines
end

private def nvs_insert(w, pos, text)
  w.text_cursor = Crysterm::TextCursor.new(w.document, pos)
  w.text_cursor.insert_text text
end

describe Crysterm::Neovim::Handler do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  it "keeps a widget change and a Neovim change on other lines that crossed" do
    window = nvs_window
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "a\nb\nc\nd\ne\n"
    h = Crysterm::Neovim::Handler.new
    h.attach(w).should be_true
    # Neovim deletes the first line; the widget changes the fourth.
    nvs_nvim_set h, 0, 1, [] of String
    nvs_insert w, 6, "D"
    nvs_settle h, w
    w.value.should eq "b\nc\nDd\ne\n"
    nvs_lines(h).should eq ["b", "c", "Dd", "e"]
    # And the other way round: Neovim's change after the widget's.
    nvs_nvim_set h, 3, 4, ["E"]
    nvs_insert w, 0, "B"
    nvs_settle h, w
    w.value.should eq "Bb\nc\nDd\nE\n"
    nvs_lines(h).should eq ["Bb", "c", "Dd", "E"]
    h.attached?.should be_true
  ensure
    h.try &.detach
    window.try &.destroy
  end

  it "lets the widget's change win over a Neovim change of the same lines" do
    window = nvs_window
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "a\nb\nc\n"
    h = Crysterm::Neovim::Handler.new
    h.attach(w).should be_true
    nvs_nvim_set h, 1, 2, ["nvim", "more"]
    nvs_insert w, 2, "w"
    nvs_settle h, w
    w.value.should eq "a\nwb\nc\n"
    nvs_lines(h).should eq ["a", "wb", "c"]
  ensure
    h.try &.detach
    window.try &.destroy
  end

  it "lets a reset of the widget's document win over a Neovim change on its way" do
    window = nvs_window
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "a\nb\nc\n"
    h = Crysterm::Neovim::Handler.new
    h.attach(w).should be_true
    nvs_nvim_set h, 0, 1, [] of String
    w.plain_text = "x\ny\n"
    nvs_settle h, w
    w.value.should eq "x\ny\n"
    nvs_lines(h).should eq ["x", "y"]
  ensure
    h.try &.detach
    window.try &.destroy
  end

  it "lets go of a Neovim that does not answer within request_timeout" do
    window = nvs_window
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "a\n"
    h = Crysterm::Neovim::Handler.new
    h.sync_timeout = 100.milliseconds
    h.request_timeout = 300.milliseconds
    reasons = [] of String
    h.on(Crysterm::Event::ViDetached) { |e| reasons << e.reason }
    h.attach(w).should be_true
    # Uninterruptible: Lua does not look for Ctrl-C.
    h.input ":lua while true do end<CR>"
    started = Time.instant
    nvs_insert w, 0, "x"
    h.sync
    (Time.instant - started).should be < 3.seconds
    h.attached?.should be_false
    reasons.should eq ["Neovim did not answer within 0.3 s"]
    w.value.should eq "xa\n"
  ensure
    h.try &.detach
    window.try &.destroy
  end

  it "sends Ctrl-C to a busy Neovim while a change waits on it" do
    window = nvs_window
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "a\n"
    h = Crysterm::Neovim::Handler.new
    h.sync_timeout = 100.milliseconds
    h.attach(w).should be_true
    h.input ":while 1|endwhile<CR>"
    nvs_insert w, 0, "x"
    # The change goes on its own fiber, which waits on the busy Neovim.
    sleep 50.milliseconds
    started = Time.instant
    h.input "<C-c>"
    nvs_settle h, w
    (Time.instant - started).should be < 2.seconds
    h.attached?.should be_true
    nvs_lines(h).should eq ["xa"]
  ensure
    h.try &.detach
    window.try &.destroy
  end

  it "follows another document set on the widget" do
    window = nvs_window
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "old\n"
    old = w.document
    h = Crysterm::Neovim::Handler.new
    h.attach(w).should be_true
    doc = Crysterm::TextDocument.new
    doc.set_plain_text "new\ntext\n"
    w.document = doc
    nvs_settle h, w
    nvs_lines(h).should eq ["new", "text"]
    # The old document's history is not Neovim's to undo into.
    h.input "u"
    w.value.should eq "new\ntext\n"
    # The new document's edits reach Neovim, the old one's no longer.
    nvs_insert w, 0, "a "
    Crysterm::TextCursor.new(old, 0).insert_text "gone "
    nvs_settle h, w
    nvs_lines(h).should eq ["a new", "text"]
  ensure
    h.try &.detach
    window.try &.destroy
  end

  it "tells :w FILE, a copy, from :saveas FILE and :file FILE, a new name" do
    window = nvs_window
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    w.value = "a\n"
    h = Crysterm::Neovim::Handler.new
    writes = [] of {String?, Bool}
    h.on(Crysterm::Event::ViWriteRequested) { |e| writes << {e.path, e.rename} }
    h.attach(w).should be_true
    dir = File.realpath(Dir.tempdir)
    copy = File.join(dir, "crysterm-nvs-#{Process.pid}-copy")
    named = File.join(dir, "crysterm-nvs-#{Process.pid}-named")
    other = File.join(dir, "crysterm-nvs-#{Process.pid}-other")
    name = "crysterm://#{h.buffer}"
    client = h.client.not_nil!
    h.input "x:w #{copy}<CR>"
    # A copy written leaves the buffer modified, as in Vim.
    client.request("nvim_exec_lua", "return vim.bo[...].modified", [h.buffer]).as_bool.should be_true
    h.input ":saveas #{named}<CR>"
    h.input ":file #{other}<CR>"
    h.input ":w<CR>"
    h.input ":w<CR>"
    h.sync
    writes.should eq [{copy, false}, {named, true}, {other, true}, {nil, false}]
    client.request("nvim_buf_get_name", h.buffer).as_s.should eq name
    # No buffer is left holding the names.
    client.request("nvim_exec_lua", "local n = {} for _, b in ipairs(vim.api.nvim_list_bufs()) do n[#n + 1] = vim.api.nvim_buf_get_name(b) end return n", [] of String)
      .as_a.map(&.to_s).should_not contain(named)
    h.attached?.should be_true
  ensure
    h.try &.detach
    window.try &.destroy
  end
end
