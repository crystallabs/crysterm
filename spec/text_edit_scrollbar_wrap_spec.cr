require "./spec_helper"

include Crysterm

private IMAGE_DIR = File.expand_path("#{__DIR__}/../data/image")

# `Widget::TextEdit` lays its rows out inside the right-edge reservation its
# layout was keyed on (`content_margin_x`: the scroll bar and the caret's
# end-of-line column), as `PlainTextEdit` does: rows wrap against it (not
# against one read after the rows were cleared, where an `AsNeeded` bar
# looked absent), aligned rows and pictures fit within it, and full-width
# fills and frame bars leave the scroll bar's column to the bar.
describe "TextEdit beside a scroll bar" do
  it "wraps at the content width, as PlainTextEdit does" do
    text = "abcdefghijklmnop\nqrstuvwxyz0123456789ABCDEFGH"
    s = headless_screen(9, 5, default_quit_keys: true)
    te = Widget::TextEdit.new(parent: s, left: 0, top: 0, width: 9, height: 5, content: text)
    s.repaint
    te.content_width.should eq 7
    rich = (0...5).map { |y| row_text(s, y, 0...7) }
    rich.each(&.rstrip.size.should(be <= 7))
    row_text(s, 4, 0...7).should eq "BCDEFGH"

    te.hide
    pe = Widget::PlainTextEdit.new(parent: s, left: 0, top: 0, width: 9, height: 5, content: text)
    s.repaint
    (0...5).map { |y| row_text(s, y, 0...7) }.should eq rich
    pe.content_width.should eq 7
  end

  it "keeps right-aligned rows, rules, code fills, frame bars and pictures off the bar" do
    s = headless_screen(20, 6, default_quit_keys: true)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 20, height: 6
    te.document.base_url = IMAGE_DIR
    te.set_markdown("para\n\n---\n\n```\ncode\n```\n\n" + (["more text"] * 6).join("\n\n"))
    te.document.cursor(0, 0).set_block_format(TextBlockFormat.new(alignment: Tput::AlignFlag::Right))
    s.repaint
    te.show_scrollbar?.should be_true
    te.content_width.should eq 18
    row_text(s, 0, 0...19).should eq "              para "
    row_text(s, 2, 18...19).should eq "─"
    (0...6).each { |y| row_text(s, y, 19...20).should_not eq "─" }
    code_bg = Attr.bg(s.cell_rows[4][18].attr)
    Attr.bg(s.cell_rows[4][19].attr).should_not eq code_bg

    te.set_markdown("para para\n\n" + (["more text"] * 6).join("\n\n"))
    te.document.cursor(0, 0).insert_frame(TextFrameFormat.new(border: true))
    s.repaint
    row_text(s, 0, 0...19).should eq "┌─────────────────┐"
    row_text(s, 1, 18...19).should eq "│"
    row_text(s, 1, 19...20).should_not eq "│"

    # 24 × 4.2 cells naturally, shrunk to the 19 columns left of the bar (a
    # picture may take the caret's end-of-line column).
    s = headless_screen(20, 20, default_quit_keys: true)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 20, height: 20
    te.document.base_url = IMAGE_DIR
    te.set_markdown("![Matterhorn](matterhorn.png)\n\n" + (["more text"] * 12).join("\n\n"))
    s.repaint
    te.show_scrollbar?.should be_true
    te.block_media.first.awidth.should eq 19
  end
end
