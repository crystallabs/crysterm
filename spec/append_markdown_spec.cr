require "./spec_helper"

include Crysterm

# Streaming markdown append (`TextMarkdown::Stream` / `TextDocument#append_markdown`
# / `TextEdit#append_markdown`). The core contract is
# *seam equality*: any chunking of a markdown text — plus a final
# `flush_markdown` — must produce the same document as parsing it whole, because
# the stream only releases prefixes at blank lines no construct can reach back
# across (fences, tables, lists, HTML blocks, TOC fences, unterminated
# paragraphs all wait). Verified property-style below: for each fixture, every
# 2-way split point and a char-by-char drip must match the one-shot parse.

# Fixture documents, each aimed at a construct that must survive arbitrary
# chunk seams.
private FIXTURES = {
  "paragraph continuation and breaks"              => "First paragraph line one\nline two continues\n\nSecond paragraph\\\nhard break tail\n\nThird **bold** and `code` span",
  "fenced code straddle"                           => "Intro paragraph\n\n```crystal\ndef x\n\n  y = 1\nend\n```\n\nAfter fence",
  "tilde fence with backticks inside"              => "~~~\ncode ` with ``` ticks\n~~~\n\ntail after tilde",
  "table straddle"                                 => "Before table\n\n| h1 | h2 |\n| --- | :-: |\n| a | b |\n| c | d |\n\nAfter table",
  "lists, continuations and closers"               => "- one\n- two\n  - sub\n\n  continuation of two\n\n1. first\n2. second\n\nplain closer\n\n# after lists\n\ntail",
  "quotes and alerts"                              => "> quoted line\n> more quote\n\n> [!NOTE]\n> alert body\n> second line\n\nafter quotes",
  "headings, rule, setext"                         => "# Title\n\n## Sub\n\n---\n\nSetext\n===\n\nplain end",
  "html blocks (type 6 and blank-crossing type 2)" => "<div class=\"x\">\nraw html\n</div>\n\n<!-- comment\nspans\n\nblank -->\n\nafter html",
  "multibyte and emoji"                            => "Emoji 👨‍👩‍👧‍👦 family and 🇭🇷 flag\n\nCafé naïve — ellipsis…\n\n漢字とかな mixed **太字** bold",
  "toc fence region"                               => "# One\n\n<!-- toc -->\n\n- [One](#one)\n\n<!-- tocstop -->\n\n## Two\n\nbody text",
  "bare toc marker"                                => "# A\n\n[TOC]\n\n## B\n\nbody",
}

# A value-comparable snapshot of a document's full structure. Formats compare
# by value (`def_equals`) except frame/table formats, whose *instance identity*
# is the semantic (one list vs. two value-equal lists exports differently) —
# identities are canonicalized to first-seen indexes so two independently
# parsed documents compare equal exactly when their sharing structure matches.
private def doc_signature(doc : Crysterm::TextDocument)
  ids = {} of UInt64 => Int32
  canon = ->(oid : UInt64) { ids[oid] ||= ids.size }
  doc.blocks.map do |b|
    bf = b.block_format
    {
      b.text,
      b.fragments.map(&.text),
      b.fragments.map(&.format),
      bf.alignment, bf.indent, bf.top_margin, bf.bottom_margin, bf.bg,
      bf.heading_level, bf.quote_level, bf.horizontal_rule?, bf.checked?,
      bf.alert_kind,
      bf.list_format.try { |lf| {lf.style, lf.indent, lf.start, canon.call(lf.object_id)} },
      bf.table_format.try { |tf| {tf.columns, tf.alignments, canon.call(tf.object_id)} },
      bf.frame_formats.try(&.map { |f| {f.class.name, f.margin, f.border?, canon.call(f.object_id)} }),
    }
  end
end

# Streams *md* in every 2-way split plus a char-by-char drip, asserting each
# result matches the one-shot `TextDocument.from_markdown` — structurally
# (`doc_signature`) and on markdown export. Both sides end refreshed:
# `from_markdown` refreshes TOCs itself; streaming refreshes manually at
# end-of-stream (append never does — that is asserted separately).
private def assert_split_property(md : String, label : String, file = __FILE__, line = __LINE__)
  base = Crysterm::TextDocument.from_markdown(md)
  base_sig = doc_signature(base)
  base_md = base.to_markdown
  splits = (0..md.size).map { |i| [md[0, i], md[i..]].reject(&.empty?) }
  splits << md.chars.map(&.to_s) # drip-feed: every char its own chunk
  splits.each_with_index do |chunks, idx|
    streamed = Crysterm::TextDocument.new
    chunks.each { |c| streamed.append_markdown c }
    streamed.flush_markdown
    streamed.refresh_tocs
    sig = doc_signature(streamed)
    next if sig == base_sig && streamed.to_markdown == base_md
    di = (0...Math.max(sig.size, base_sig.size)).find { |j| sig[j]? != base_sig[j]? }
    where = idx <= md.size ? "cut at char #{idx}" : "char-by-char drip"
    fail "#{label} (#{where}): streamed parse diverged from one-shot at block #{di}\n" \
         "one-shot: #{di.try { |j| base_sig[j]? }.inspect}\n" \
         "streamed: #{di.try { |j| sig[j]? }.inspect}\n" \
         "one-shot md: #{base_md.inspect}\n" \
         "streamed md: #{streamed.to_markdown.inspect}",
      file: file, line: line
  end
end

describe Crysterm::TextMarkdown::Stream do
  it "releases a blank-terminated paragraph and keeps the unterminated tail pending" do
    s = Crysterm::TextMarkdown::Stream.new
    s.append("First para\n\nSecond par").should eq "First para\n\n"
    s.pending.should eq "Second par"
    # A complete line without a terminating blank line still waits.
    s.append("agraph grows\n").should be_nil
    s.flush.should eq "Second paragraph grows\n"
    s.pending.should eq ""
  end

  it "holds an open fence across blank lines until it closes" do
    s = Crysterm::TextMarkdown::Stream.new
    s.append("```\ncode\n\nstill code\n").should be_nil
    s.append("```\n\nafter\n\n").should eq "```\ncode\n\nstill code\n```\n\nafter\n\n"
  end

  it "holds a list across blank lines until a column-0 plain line closes it" do
    s = Crysterm::TextMarkdown::Stream.new
    # "- b" (or an indented continuation) may still follow: unsafe to cut.
    s.append("- a\n\n- b\n\n").should be_nil
    s.append("closer\n\n").should eq "- a\n\n- b\n\ncloser\n\n"
  end

  it "holds abutting quote runs together (the importer itself separates them)" do
    s = Crysterm::TextMarkdown::Stream.new
    # A cut between "> a" and "> b" would lose the quote-interior separator
    # block one-shot import emits between abutting quote runs.
    s.append("> a\n\n> b\n\n").should be_nil
    s.append("closer\n\n").should eq "> a\n\n> b\n\ncloser\n\n"
  end

  it "releases a table only at its terminating blank line" do
    s = Crysterm::TextMarkdown::Stream.new
    s.append("| a | b |\n| - | - |\n| 1 ").should be_nil
    s.append("| 2 |\n").should be_nil
    s.append("\ntail\n\n").should eq "| a | b |\n| - | - |\n| 1 | 2 |\n\ntail\n\n"
  end

  it "keeps a <!-- toc --> region whole until its tocstop" do
    s = Crysterm::TextMarkdown::Stream.new
    s.append("<!-- toc -->\n\n- [x](#x)\n\n").should be_nil
    s.append("<!-- tocstop -->\n\nnext\n\n")
      .should eq "<!-- toc -->\n\n- [x](#x)\n\n<!-- tocstop -->\n\nnext\n\n"
  end

  it "treats a whitespace-only stream as nothing" do
    s = Crysterm::TextMarkdown::Stream.new
    s.append("  \n\n").should be_nil
    s.flush.should be_nil
  end
end

describe "TextDocument#append_markdown" do
  describe "seam equality" do
    FIXTURES.each do |label, md|
      it "streams #{label} identically to one-shot parsing at every split point" do
        assert_split_property(md, label)
      end
    end
  end

  it "merges a paragraph split mid-word exactly like one-shot parsing" do
    doc = TextDocument.new
    doc.append_markdown "Hello wo"
    doc.append_markdown "rld\n\nNext para\n"
    doc.flush_markdown
    doc.blocks.map(&.text).should eq ["Hello world", "Next para"]
    # The seam blank line lands as the following block's top margin, exactly
    # where one-shot import puts it.
    doc.blocks[1].block_format.top_margin.should eq 1
    doc.to_markdown.should eq "Hello world\n\nNext para"
  end

  it "buffers an unterminated heading and commits it at its blank line" do
    doc = TextDocument.new
    doc.append_markdown "# Ti"
    doc.blocks.map(&.text).should eq [""] # nothing committed yet
    doc.append_markdown "tle\n\nbody "
    doc.blocks.map(&.text).should eq ["Title"] # heading landed, body pending
    doc.blocks[0].block_format.heading_level.should eq 1
    doc.append_markdown "text\n"
    doc.flush_markdown
    doc.to_markdown.should eq "# Title\n\nbody text"
  end

  it "does not refresh inline TOCs on append (refresh is manual)" do
    doc = TextDocument.new
    doc.append_markdown "# One\n\n<!-- toc -->\n<!-- tocstop -->\n\n"
    doc.append_markdown "## Two\n\nbody\n"
    doc.flush_markdown
    toc_blocks = doc.blocks.select { |b| b.block_format.frame_formats.try(&.any?(TextTocFormat)) }
    # The streamed-in region folded into a TOC frame but stays empty — no
    # entries are generated behind the reader's back mid-stream.
    toc_blocks.map(&.text).should eq [""]
    # End of stream: the application refreshes, and the entries appear.
    doc.refresh_tocs.should be_true
    entries = doc.blocks.select { |b| b.block_format.frame_formats.try(&.any?(TextTocFormat)) }
    entries.any?(&.text.includes?("Two")).should be_true
  end
end

describe "Widget::TextEdit#append_markdown" do
  it "streams into the document, relayouts, and leaves the caret alone" do
    s = headless_screen(40, 10)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 30, height: 8
    s.repaint
    te.append_markdown "# Hi\n\nbo"
    te.append_markdown "dy text\n"
    te.flush_markdown
    te.to_markdown.should eq "# Hi\n\nbody text"
    te.cursor_pos.should eq 0
    s.repaint
    te.wrapped_lines.lines.join(' ').should contain "body text"
  end

  it "is inherited by TextBrowser (the CHATBOX streaming consumer)" do
    s = headless_screen(40, 10)
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 30, height: 8
    s.repaint
    tb.append_markdown "See [docs](https://example.com)\n\n"
    tb.flush_markdown
    tb.links.map(&.url).should eq ["https://example.com"]
  end
end
