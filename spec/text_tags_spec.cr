require "./spec_helper"

include Crysterm

# Tag-markup interchange (`TextTags`, TEXTEDIT.md Phase 3): the native
# serialization of `TextDocument` content. Pure model, no screen needed.

private def doc_from(tags : String) : Crysterm::TextDocument
  Crysterm::TextDocument.from_tags(tags)
end

describe Crysterm::TextTags do
  describe ".parse" do
    it "parses plain text into blocks on newlines" do
      doc = doc_from "one\ntwo"
      doc.block_count.should eq 2
      doc.to_plain_text.should eq "one\ntwo"
    end

    it "parses flag tags into char formats" do
      doc = doc_from "a{bold}b{/bold}c"
      doc.to_plain_text.should eq "abc"
      b = doc.blocks[0]
      b.fragments.size.should eq 3
      b.fragments[0].format.bold?.should be_false
      b.fragments[1].format.bold?.should be_true
      b.fragments[2].format.bold?.should be_false
    end

    it "parses all flag aliases" do
      doc = doc_from "{ul}u{/ul}{strikethrough}s{/strikethrough}{reverse}i{/reverse}{dim}d{/dim}{code}c{/code}"
      f = doc.blocks[0].fragments
      f[0].format.underline?.should be_true
      f[1].format.strike?.should be_true
      f[2].format.inverse?.should be_true
      f[3].format.dim?.should be_true
      f[4].format.code?.should be_true
    end

    it "parses hex and named colors" do
      doc = doc_from "{#ff0000-fg}r{/#ff0000-fg}{blue-bg}b{/blue-bg}"
      f = doc.blocks[0].fragments
      f[0].format.fg.should eq 0xFF0000
      f[1].format.bg.should eq Colors.convert_cached("blue")
    end

    it "restores the enclosing color when a nested color closes" do
      doc = doc_from "{#ff0000-fg}a{#00ff00-fg}b{/#00ff00-fg}c{/#ff0000-fg}"
      f = doc.blocks[0].fragments
      f[0].format.fg.should eq 0xFF0000
      f[1].format.fg.should eq 0x00FF00
      f[2].format.fg.should eq 0xFF0000
      # a and c merge? no — b sits between them, so three runs
      f.size.should eq 3
    end

    it "resets all char formats on {/}" do
      doc = doc_from "{bold}{#ff0000-fg}a{/}b"
      f = doc.blocks[0].fragments
      f[0].format.bold?.should be_true
      f[1].format.bold?.should be_false
      f[1].format.fg.should be_nil
    end

    it "emits literal braces for {open}/{close} and preserves {escape} bodies" do
      doc_from("{open}x{close}").to_plain_text.should eq "{x}"
      doc_from("{escape}{bold}{/escape}").to_plain_text.should eq "{bold}"
    end

    it "drops unknown tags and stray braces (only the brace itself)" do
      doc_from("a{nosuchtag}b{c").to_plain_text.should eq "abc"
    end

    it "parses {link=URL} into anchors" do
      doc = doc_from "see {link=https://example.com}here{/link}!"
      f = doc.blocks[0].fragments
      f[1].format.anchor_href.should eq "https://example.com"
      f[1].text.should eq "here"
      f[2].format.anchor_href.should be_nil
    end

    it "parses the {!block;...} prefix into block formats" do
      doc = doc_from "{!block;h2;indent-4;mt-1;mb-2;bg-#123456;nobreak}head"
      bf = doc.blocks[0].block_format
      bf.heading_level.should eq 2
      bf.indent.should eq 4
      bf.top_margin.should eq 1
      bf.bottom_margin.should eq 2
      bf.bg.should eq 0x123456
      bf.non_breakable?.should be_true
      doc.to_plain_text.should eq "head"
    end

    it "applies alignment wrapping tags to the block format" do
      doc = doc_from "{center}mid{/center}\nplain"
      doc.blocks[0].block_format.alignment.should eq Tput::AlignFlag::HCenter
      doc.blocks[1].block_format.alignment.should be_nil
    end

    it "carries an open alignment across blocks" do
      doc = doc_from "{center}a\nb{/center}\nc"
      doc.blocks[0].block_format.alignment.should eq Tput::AlignFlag::HCenter
      doc.blocks[1].block_format.alignment.should eq Tput::AlignFlag::HCenter
      doc.blocks[2].block_format.alignment.should be_nil
    end
  end

  describe ".generate" do
    it "round-trips text, char formats and block formats" do
      doc = TextDocument.new("hello world\nsecond line")
      doc.apply_char_format(0, 5, TextCharFormat.new(bold: true, fg: 0xFF0000))
      doc.apply_char_format(6, 11, TextCharFormat.new(italic: true, underline: true, bg: 0x00FF00))
      doc.apply_block_format(12, 12, TextBlockFormat.new(heading_level: 3, alignment: Tput::AlignFlag::HCenter))

      tags = doc.to_tags
      doc2 = TextDocument.from_tags(tags)

      doc2.to_plain_text.should eq doc.to_plain_text
      doc2.char_format_runs(0, doc2.size).size.should eq doc.char_format_runs(0, doc.size).size
      doc.char_format_runs(0, doc.size).zip(doc2.char_format_runs(0, doc2.size)) do |(s1, e1, f1), (s2, e2, f2)|
        s2.should eq s1
        e2.should eq e1
        f2.same_appearance?(f1).should be_true
      end
      bf2 = doc2.blocks[1].block_format
      bf2.heading_level.should eq 3
      bf2.alignment.should eq Tput::AlignFlag::HCenter
    end

    it "round-trips anchors" do
      doc = TextDocument.new("click me")
      doc.apply_char_format(6, 8, TextCharFormat.new(anchor_href: "http://x.io/{a}"))
      doc2 = TextDocument.from_tags(doc.to_tags)
      doc2.char_format_at(8).anchor_href.should eq "http://x.io/{a}"
    end

    it "escapes literal braces" do
      doc = TextDocument.new("a {b} c")
      doc.to_tags.should contain "{open}"
      TextDocument.from_tags(doc.to_tags).to_plain_text.should eq "a {b} c"
    end

    it "serializes empty documents/blocks losslessly" do
      TextDocument.from_tags(TextDocument.new("").to_tags).to_plain_text.should eq ""
      TextDocument.from_tags(TextDocument.new("a\n\nb").to_tags).to_plain_text.should eq "a\n\nb"
    end
  end
end

describe Crysterm::TextDocumentFragment do
  it "converts from and to tags" do
    frag = TextDocumentFragment.from_tags("{bold}x{/bold}")
    frag.blocks[0].fragments[0].format.bold?.should be_true
    frag.to_tags.should eq "{bold}x{/bold}"
  end
end
