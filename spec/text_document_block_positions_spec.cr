require "./spec_helper"

# The block position tree stays exact across every kind of edit: a typing
# edit re-records one block's length in place, structural edits rebuild.
private def naive_positions(doc : Crysterm::TextDocument) : Array(Int32)
  out = [] of Int32
  pos = 0
  doc.blocks.each do |b|
    out << pos
    pos += b.size + 1
  end
  out
end

private def check(doc : Crysterm::TextDocument) : Nil
  want = naive_positions(doc)
  doc.block_count.should eq want.size
  want.each_with_index { |p, i| doc.block_position(i).should eq p }
  doc.size.should eq(want.last + doc.blocks.last.size)
  (0..doc.size).each do |p|
    loc = doc.block_at(p)
    i = want.rindex { |s| s <= p } || 0
    loc.index.should eq i
    loc.offset.should eq((p - want[i]).clamp(0, doc.blocks[i].size))
  end
  doc.block_at(doc.size + 5).index.should eq(doc.block_count - 1)
end

describe "TextDocument block positions" do
  it "tracks typing, newlines, removals across blocks, undo and resets" do
    doc = Crysterm::TextDocument.new("alpha\nbeta\n\ngamma delta")
    check doc
    c = doc.cursor(3)
    c.insert_text("XY") # inside the first block
    check doc
    doc.cursor(doc.size).insert_text("zz") # end of the last block
    check doc
    doc.cursor(0).insert_text("a\nb") # splits the first block
    check doc
    doc.cursor(1, 9).remove_selected_text # across a separator
    check doc
    doc.cursor(doc.block_position(1)).insert_text("\n\n") # empty blocks
    check doc
    doc.cursor(0, doc.size).remove_selected_text # everything
    check doc
    doc.undo
    check doc
    doc.redo
    check doc
    doc.set_plain_text("one\ntwo\nthree")
    check doc
    doc.cursor(4, 7).remove_selected_text # whole middle block's text
    check doc
    doc.cursor(4).insert_text("TWO")
    check doc
  end

  it "stays exact over random edits" do
    rng = Random.new(42)
    doc = Crysterm::TextDocument.new(Array.new(40) { |i| "line #{i} " + "x" * (i % 7) }.join('\n'))
    check doc
    200.times do
      case rng.rand(4)
      when 0
        doc.cursor(rng.rand(doc.size + 1)).insert_text(rng.rand(3) == 0 ? "a\nb" : "q")
      when 1
        from = rng.rand(doc.size + 1)
        to = Math.min(doc.size, from + rng.rand(12))
        doc.cursor(from, to).remove_selected_text if to > from
      when 2
        doc.undo
      else
        doc.redo
      end
      check doc
    end
  end
end
