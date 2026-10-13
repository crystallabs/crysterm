require "./spec_helper"

include Crysterm

# Edge cases of `Widget::PlainTextEdit`'s display patch
# (`Widget#replace_content_lines`): wide characters, the line-number gutter
# (whose width grows with the line count), edits that empty the document or
# start from an empty one, and edits at the document's end. Every state must
# match a fresh editor over the same text, as in
# `plain_text_edit_line_replace_spec.cr`.

private W = 24
private H =  4

private def new_editor(text, wrap, numbers)
  s = headless_screen(60, 20)
  pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: W, height: H,
    wrap_content: wrap, content: text
  pte.line_numbers = numbers
  s.repaint
  {s, pte}
end

private def expect_identical(pte, wrap, numbers)
  s = headless_screen(60, 20)
  ref = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: W, height: H,
    wrap_content: wrap, content: pte.value
  ref.line_numbers = numbers
  ref.child_base_x = pte.child_base_x
  s.repaint
  pc = pte.wrapped_lines
  rc = ref.wrapped_lines
  pc.lines.should eq rc.lines
  pc.fake.should eq rc.fake
  pc.ftor.should eq rc.ftor
  pc.rtof.should eq rc.rtof
  pc.max_width.should eq rc.max_width
  pc.full_width.should eq rc.full_width
  pte.content.should eq ref.content
  pte.rendered_content.should eq ref.rendered_content
end

private PIECES = ["\n", "a\nb", "漢字", "x\n\n😀y", "wide 全角の文字が続く行\n", "\t\n", "q", "\n\n\n\n\n\n\n\n\n"]

describe "Widget::PlainTextEdit display patch edges" do
  [{true, true}, {true, false}, {false, true}].each do |(wrap, numbers)|
    it "matches a fresh layout after random edits (wrap: #{wrap}, line numbers: #{numbers})" do
      s, pte = new_editor "漢字の行\nsecond\nthird 全角", wrap, numbers
      rng = Random.new(11)
      patched = 0
      240.times do |i|
        size = pte.document.size
        case rng.rand(6)
        when 0
          # Empty the whole document, then type into it again.
          if size > 0
            pte.selection_anchor = 0
            pte.cursor_pos = size
            pte.cut
            s.repaint
          end
        when 1, 2
          if size > 1
            pos = rng.rand(size)
            pte.selection_anchor = pos
            pte.cursor_pos = Math.min(size, pos + rng.rand(1..15))
            pte.cut
            s.repaint
          end
        when 3
          # At the document's end.
          pte.cursor_pos = size
          pte.insert_text PIECES.sample(rng)
          patched += 1 if pte.@_content_stale
          s.repaint
        else
          pte.cursor_pos = rng.rand(size + 1)
          pte.insert_text PIECES.sample(rng)
          patched += 1 if pte.@_content_stale
          s.repaint
        end
        expect_identical pte, wrap, numbers if i % 20 == 19
      end
      expect_identical pte, wrap, numbers
      # Many of the inserts took the patch, not the full push.
      patched.should be > 40
    end
  end
end
