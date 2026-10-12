require "./spec_helper"

include Crysterm

private def table_of(doc : TextDocument) : TextTable
  TextTable.new(doc, doc.blocks.find!(&.block_format.table_format).block_format.table_format.not_nil!)
end

describe TextTable do
  it "keeps a space typed at a word's mid-way break, though the rendering is the same" do
    doc = TextDocument.new
    doc.text_width = 12
    doc.set_markdown "| A | B |\n| --- | --- |\n| abcdefghijkl | x |"
    tbl = table_of(doc)
    tbl.cell_text(1, 0).should eq "abcdefghijkl"
    # The row as it looks: a space at each break of the word.
    spaced = TextTable.split_data_row(tbl.row_block(1).not_nil!.text)[0]
    spaced.should_not eq "abcdefghijkl"
    tbl.set_cell_text(1, 0, spaced).should be_true
    tbl.cell_text(1, 0).should eq spaced
    doc.to_markdown.should contain spaced
  end
end

private GFM = <<-MD
  | Key | What it does |
  | --- | --- |
  | F1 | Shows the description of the highlighted menu entry beside it until the next key |
  | F5 | Cycles the mouse modes |
  MD

describe TextDocument do
  it "keeps the undo history across a reflow, undo and redo restoring the text at the width of the day" do
    doc = TextDocument.new
    doc.set_markdown GFM + "\n\npara"
    natural = doc.to_plain_text
    doc.cursor(doc.size).insert_text("!")
    typed = doc.to_plain_text
    doc.text_width = 30
    doc.modified?.should be_true
    doc.undo_available?.should be_true
    narrow = doc.to_plain_text
    narrow.should_not eq typed
    doc.undo.should be_true
    doc.to_plain_text.should eq narrow.rchop("!")
    doc.modified?.should be_false
    doc.text_width = nil
    doc.to_plain_text.should eq natural
    doc.redo.should be_true
    doc.to_plain_text.should eq typed
    doc.text_width = 30
    doc.undo.should be_true
    doc.text_width = nil
    doc.to_plain_text.should eq natural
  end

  it "undoes a cell edit made at another width" do
    doc = TextDocument.new
    doc.set_markdown GFM
    natural = doc.to_markdown
    tbl = table_of(doc)
    tbl.set_cell_text(2, 1, "Cycles the mouse modes and more").should be_true
    edited = doc.to_markdown
    doc.text_width = 30
    doc.undo.should be_true
    doc.to_markdown.should eq natural
    doc.redo.should be_true
    doc.to_markdown.should eq edited
    doc.text_width = nil
    doc.undo.should be_true
    doc.to_markdown.should eq natural
  end
end

describe TextUndoStack do
  it "replays edits made at several widths, the text at each step as it was" do
    doc = TextDocument.new
    doc.set_markdown GFM + "\n\npara"
    tbl = table_of(doc)
    snaps = [doc.to_markdown]
    [40, 24, nil, 30].each_with_index do |w, i|
      doc.text_width = w
      if i.even?
        tbl.set_cell_text(1, 1, "#{tbl.cell_text(1, 1)} more#{i}").should be_true
      else
        doc.cursor(doc.size).insert_text("+#{i}")
      end
      snaps << doc.to_markdown
    end
    widths = [nil, 26, 50, 30]
    (snaps.size - 1).downto(1) do |k|
      doc.text_width = widths[k % widths.size]
      doc.undo.should be_true
      doc.to_markdown.should eq snaps[k - 1]
    end
    doc.undo.should be_false
    doc.modified?.should be_false
    1.upto(snaps.size - 1) do |k|
      doc.text_width = widths[(k + 1) % widths.size]
      doc.redo.should be_true
      doc.to_markdown.should eq snaps[k]
    end
    # Rendered at the width of the day throughout.
    doc.text_width = 30
    w = doc.blocks.select(&.block_format.table_format).flat_map { |b| TextTable.display_lines(b.text) }.map { |l| Crysterm::Unicode.display_width(l) }.uniq!
    w.should eq [30]
  end

  it "keeps one re-rendering per table however many widths it goes through" do
    doc = TextDocument.new
    doc.set_markdown GFM + "\n\n" + GFM + "\n\npara"
    doc.cursor(doc.size).insert_text("!")
    typed = doc.to_plain_text
    stack = doc.@undo_stack.not_nil!
    (20..60).each { |w| doc.text_width = w }
    stack.@reflows.size.should eq 2
    doc.text_width = nil
    stack.@reflows.should be_empty
    doc.to_plain_text.should eq typed
    (20..60).each { |w| doc.text_width = w }
    doc.undo.should be_true
    doc.text_width = nil
    doc.to_plain_text.should eq typed.rchop("!")
  end

  it "still drops the history for a reflow inside an edit block" do
    doc = TextDocument.new
    doc.set_markdown GFM + "\n\npara"
    doc.cursor(doc.size).insert_text("!")
    doc.edit do
      doc.cursor(doc.size).insert_text("?")
      doc.text_width = 30
    end
    doc.modified?.should be_true
  end
end

describe Widget::TextEdit do
  it "keeps the undo history when the scroll bar comes up under a wrapped table" do
    s = headless_screen(60, 24, default_quit_keys: true)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 30, height: 18, scrollable: true
    te.set_markdown GFM + "\n\npara"
    s.repaint
    before = te.document.to_markdown
    te.cursor_pos = te.document.size
    width = te.document.text_width
    12.times do
      te._listener Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Enter
      s.repaint
    end
    te.document.text_width.should_not eq width
    te.show_scrollbar?.should be_true
    # Every Enter undoes, back to the text as it was set.
    12.times { te.document.undo.should be_true }
    te.document.to_markdown.should eq before
  end
end
