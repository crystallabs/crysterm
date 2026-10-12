require "./spec_helper"

# `Neovim::Handler` moving a widget's caret: a move Neovim makes (`j`, `G`,
# `w`, an insert) is a caret move of the widget as any other — it emits
# `Event::CursorPositionChanged`, and what follows the caret, the current
# line's tint (`highlight_current_line`), follows it.

private def nvc_window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10, default_quit_keys: false)
end

private def nvc_type(w, text : String)
  text.scan(/<[^>]+>|./m) do |m|
    e = m[0] == "<Esc>" ? Crysterm::Event::KeyPress.new('\e', Tput::Key::Escape) : Crysterm::Event::KeyPress.new(m[0][0], nil)
    w.emit e
  end
end

# Background of the cell at column *col* of *w*'s viewport row *row*.
private def nvc_bg(window, w, row, col = 2)
  Crysterm::Attr.bg(window.cell_rows[w.atop + row][w.aleft + col].attr)
end

# The viewport rows of *w* whose background is the current line's tint.
private def nvc_tinted(window, w, plain) : Array(Int32)
  window.repaint
  (0...5).select { |row| nvc_bg(window, w, row) != plain }
end

describe Crysterm::Neovim::Handler do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  {% for type in %w(PlainTextEdit TextEdit) %}
    it "moves a {{type.id}}'s caret as the widget's own moves do: events, the current line's tint" do
      window = nvc_window
      w = Crysterm::Widget::{{type.id}}.new parent: window, left: 0, top: 0, width: 40, height: 8
      w.value = "one\ntwo\nthree\nfour\nfive"
      w.cursor_pos = 0
      window.repaint
      plain = nvc_bg(window, w, 4)
      w.highlight_current_line = true
      moves = [] of Int32
      w.on(Crysterm::Event::CursorPositionChanged) { |e| moves << e.position }
      h = Crysterm::Neovim::Handler.new
      h.attach(w).should be_true
      begin
        nvc_tinted(window, w, plain).should eq [0]
        nvc_type w, "j"
        moves.last.should eq 4
        nvc_tinted(window, w, plain).should eq [1]
        nvc_type w, "G"
        nvc_tinted(window, w, plain).should eq [4]
        nvc_type w, "ggjjl"
        nvc_tinted(window, w, plain).should eq [2]
        nvc_type w, "Oinserted<Esc>"
        w.value.should eq "one\ntwo\ninserted\nthree\nfour\nfive"
        nvc_tinted(window, w, plain).should eq [2]
        nvc_type w, "j"
        nvc_tinted(window, w, plain).should eq [3]
        moves.last.should eq w.cursor_pos
      ensure
        h.detach
        window.destroy
      end
    end
  {% end %}
end
