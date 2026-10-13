require "./spec_helper"

# Wrapping one long line costs time linear in its length: the cut for each
# row (`Unicode.wrap_cut_index`) measures only up to the cut, and a block
# imported as many alike pieces joins them in one pass (`TextBlock`).
describe "long line wrapping" do
  it "cuts a visible run at the column budget, an SGR run or a stray escape around it" do
    u = Crysterm::Unicode
    u.wrap_cut_index("abcdef", 3, true).should eq 3
    u.wrap_cut_index("ab\e[31mcdef", 3, true).should eq 8     # the SGR run takes no columns
    u.wrap_cut_index("a\e[31mb\e[0mcd", 3, true).should eq 12 # two runs
    u.wrap_cut_index("ab\eXcdef", 3, true).should eq 4        # a stray \e is a zero-width control
    u.wrap_cut_index("a世界b", 3, true).should eq 2             # a wide cluster is not split
    u.wrap_cut_index("é\e[1mé" + "x" * 10, 2, true).should eq 6
    u.wrap_cut_index("abc", 5, true).should eq 3
  end

  it "wraps a line of 200,000 characters in time linear in its length" do
    line = "word " * 40_000
    start = Time.instant
    rows = 0
    rest = line
    while rest.size > 80
      i = Crysterm::Unicode.wrap_cut_index(rest, 80, true)
      i.should eq 80
      rest = rest[i..]
      rows += 1
    end
    rows.should eq 2499
    (Time.instant - start).should be < 2.seconds # quadratic took far longer
  end

  it "joins the alike pieces of a long block into one fragment" do
    pieces = Array.new(20_000) { |i| Crysterm::TextFragment.new("w#{i} ", Crysterm::TextCharFormat.default) }
    bold = Crysterm::TextCharFormat.new(bold: true)
    pieces << Crysterm::TextFragment.new("B", bold) << Crysterm::TextFragment.new("x", Crysterm::TextCharFormat.default)
    start = Time.instant
    block = Crysterm::TextBlock.new pieces
    (Time.instant - start).should be < 2.seconds
    block.fragments.size.should eq 3
    block.fragments[0].text.should eq (0...20_000).map { |i| "w#{i} " }.join
    block.fragments[1].text.should eq "B"
    block.text.should end_with "Bx"
  end
end
