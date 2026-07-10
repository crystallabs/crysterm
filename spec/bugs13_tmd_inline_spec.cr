require "./spec_helper"

include Crysterm

# BUGS13 T6, T15, T23, T24, T25, T26, T27 — markdown inline/escaping
# round-trip bugs.

describe "BUGS13 markdown inline round-trips" do
  # T6 — block-leading markdown syntax in plain text must be escaped or it
  # re-imports as structure.
  describe "block-leading syntax escaping (T6)" do
    it "escapes a leading bullet marker" do
      doc = TextDocument.new("- not a list")
      md = doc.to_markdown
      md.should eq "\\- not a list"
      back = TextDocument.from_markdown(md)
      back.to_plain_text.should eq "- not a list"
      back.blocks[0].block_format.list_format.should be_nil
    end

    it "escapes leading heading, quote and ordered markers" do
      ["# not a heading", "> not a quote", "1. not ordered", "12) also not"].each do |text|
        back = TextDocument.from_markdown(TextDocument.new(text).to_markdown)
        back.to_plain_text.should eq text
        back.blocks[0].block_format.heading_level.should eq 0
        back.blocks[0].block_format.quote_level.should eq 0
        back.blocks[0].block_format.list_format.should be_nil
      end
    end

    it "escapes a leading marker in list-item content" do
      # Item content that itself starts like a marker must not nest.
      doc = TextDocument.from_markdown("- \\- x")
      doc.blocks[0].text.should eq "- x"
      doc.blocks[0].block_format.list_format.should_not be_nil
      doc.to_markdown.should eq "- \\- x"
    end
  end

  # T15 — anchor URLs with spaces/parens must be encoded or the link dies.
  describe "link destination encoding (T15)" do
    it "keeps a link whose URL has spaces and an unbalanced paren" do
      doc = TextDocument.new("docs")
      doc.apply_char_format(0, 4, TextCharFormat.new(anchor_href: "http://x.com/a b(c"))
      md = doc.to_markdown
      md.should eq "[docs](http://x.com/a%20b%28c)"
      back = TextDocument.from_markdown(md)
      link = back.blocks[0].fragments[0]
      link.text.should eq "docs"
      # markd normalizes %28 back to a raw paren in the destination; the
      # link survives and the exported form is stable from here on.
      link.format.anchor_href.should eq "http://x.com/a%20b(c"
      back.to_markdown.should eq md
    end
  end

  # T23 — a code span inside a link keeps the link.
  describe "code span inside a link (T23)" do
    it "round-trips [`code`](url)" do
      md = "[`code`](http://x.com)"
      doc = TextDocument.from_markdown(md)
      f = doc.blocks[0].fragments[0]
      f.format.code?.should be_true
      f.format.anchor_href.should eq "http://x.com"
      doc.to_markdown.should eq md
    end
  end

  # T24 — strike combined with other inline markup survives a round-trip
  # (the ~~ delimiters pair across sibling inline nodes on import).
  describe "strike combined with other markup (T24)" do
    it "round-trips bold+strike" do
      doc = TextDocument.new("x")
      doc.apply_char_format(0, 1, TextCharFormat.new(bold: true, strike: true))
      md = doc.to_markdown
      md.should eq "~~**x**~~"
      f = TextDocument.from_markdown(md).blocks[0].fragments
      f.size.should eq 1
      f[0].text.should eq "x"
      f[0].format.bold?.should be_true
      f[0].format.strike?.should be_true
    end

    it "round-trips strike+link and strike+code" do
      f = TextDocument.from_markdown("~~[t](http://u)~~").blocks[0].fragments
      f.size.should eq 1
      f[0].format.strike?.should be_true
      f[0].format.anchor_href.should eq "http://u"

      doc = TextDocument.from_markdown("~~`c`~~")
      cf = doc.blocks[0].fragments[0]
      cf.format.strike?.should be_true
      cf.format.code?.should be_true
      doc.to_markdown.should eq "~~`c`~~"
    end

    it "still imports single-node strike spans and plain tildes" do
      f = TextDocument.from_markdown("a ~~gone~~ b").blocks[0].fragments
      f[1].text.should eq "gone"
      f[1].format.strike?.should be_true
      # Non-flanking tildes stay literal.
      TextDocument.from_markdown("a ~~ b").to_plain_text.should eq "a ~~ b"
    end
  end

  # T25 — code spans containing backtick runs pick a longer delimiter.
  describe "code span with backtick runs (T25)" do
    it "round-trips a code fragment containing a double-backtick run" do
      doc = TextDocument.new("a `` b")
      doc.apply_char_format(0, 6, TextCharFormat.new(code: true))
      md = doc.to_markdown
      md.should eq "``` a `` b ```"
      f = TextDocument.from_markdown(md).blocks[0].fragments[0]
      f.text.should eq "a `` b"
      f.format.code?.should be_true
    end
  end

  # T26 — literal ~~ in plain text is escaped so it doesn't gain strike.
  describe "tilde escaping in plain text (T26)" do
    it "keeps plain ~~x~~ literal through a round-trip" do
      doc = TextDocument.new("keep ~~this~~ literal")
      back = TextDocument.from_markdown(doc.to_markdown)
      back.to_plain_text.should eq "keep ~~this~~ literal"
      back.blocks[0].fragments.any?(&.format.strike?).should be_false
    end
  end

  # T27 — emphasis markers must not sit flush against fragment-edge
  # whitespace (not flanking; the markup would go literal on re-import).
  describe "emphasis edge whitespace (T27)" do
    it "hoists a trailing space out of a bold span" do
      doc = TextDocument.new("bold plain")
      doc.apply_char_format(0, 5, TextCharFormat.new(bold: true)) # "bold "
      md = doc.to_markdown
      md.should eq "**bold** plain"
      f = TextDocument.from_markdown(md).blocks[0].fragments
      f[0].text.should eq "bold"
      f[0].format.bold?.should be_true
      f[1].format.bold?.should be_false
    end

    it "hoists a leading space out of a strike span" do
      doc = TextDocument.new("plain gone")
      doc.apply_char_format(5, 10, TextCharFormat.new(strike: true)) # " gone"
      md = doc.to_markdown
      md.should eq "plain ~~gone~~"
      f = TextDocument.from_markdown(md).blocks[0].fragments
      f.last.text.should eq "gone"
      f.last.format.strike?.should be_true
    end

    it "emits no markers around a whitespace-only styled fragment" do
      doc = TextDocument.new("a b")
      doc.apply_char_format(1, 2, TextCharFormat.new(bold: true)) # just the space
      doc.to_markdown.should eq "a b"
    end
  end
end
