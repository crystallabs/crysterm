require "./spec_helper"

include Crysterm

# OPT3 O3-35 — `separator_blank?` had no html case (the fix round that added
# `html_blockish?` used it only in the backslash/hard-break guards, per the
# BUGS18.md:1121 deferral). A structured block placed directly after an
# html-blockish block therefore exported with only a bare newline, and markd's
# type-6 "continue until a blank line" rule swallowed the follower's line back
# into the html block as RAW text on re-import — silently demoting the heading
# (or leaking the "> " quote marker) on every roundtrip.
#
# The widened guard forces a blank line after an html block unless the follower
# is a plain body paragraph at the *same* quote level (that run re-imports as
# one html_block and re-splits 1:1). A quote-level mismatch also forces it,
# since `plain_body?` can't see the per-level "> " prefix write_block adds.
describe "OPT3 O3-35 html block followed by structure keeps a blank separator" do
  # (a) The type-6 case from the finding: "<div>\n# h" reads the heading back
  # as literal html text without the blank line; with it the heading survives.
  it "separates a type-6 html block from a following heading" do
    blocks = [
      TextBlock.new("<div>"),
      TextBlock.new("h", block_format: TextBlockFormat.new(heading_level: 1)),
    ]
    md = TextMarkdown.generate(blocks)
    md.should eq "<div>\n\n# h"

    round = TextDocument.from_markdown(md)
    round.blocks.map(&.text).should contain "<div>"
    heading = round.blocks.find! { |b| b.text == "h" }
    heading.block_format.heading_level.should eq 1
    # Stable across a further cycle (the accepted margin normalization).
    round.to_markdown.should eq md
  end

  # (b) A comment-closed (type-2) html block before structure. The comment is
  # already closed, so the follower survived even before this fix — but the
  # guard now normalizes the boundary to a blank line, and the heading stays.
  it "separates a comment-closed html block from a following heading" do
    blocks = [
      TextBlock.new("<!-- c -->"),
      TextBlock.new("h", block_format: TextBlockFormat.new(heading_level: 2)),
    ]
    md = TextMarkdown.generate(blocks)
    md.should eq "<!-- c -->\n\n## h"

    round = TextDocument.from_markdown(md)
    round.blocks.map(&.text).should contain "<!-- c -->"
    round.blocks.find! { |b| b.text == "h" }.block_format.heading_level.should eq 2
    round.to_markdown.should eq md
  end

  # A plain body paragraph at the *same* quote level stays a bare newline by
  # design (the exemption): the two lines re-import as one html_block and
  # re-split 1:1, so no blank line is added.
  it "keeps a bare newline before a same-level plain body follower" do
    blocks = [
      TextBlock.new("<div>x</div>"),
      TextBlock.new("plain body"),
    ]
    md = TextMarkdown.generate(blocks)
    md.should eq "<div>x</div>\nplain body"
  end

  # (c) The quote-level-mismatch increase the verifier calls out: an html
  # block at q0 followed by a quoted paragraph at q1. Without the widened
  # guard the exported "> quoted" line is swallowed into the html block and
  # re-imports as a plain q0 block carrying a leaked literal ">".
  it "separates a q0 html block from a deeper quoted follower" do
    blocks = [
      TextBlock.new("<div>x</div>"),
      TextBlock.new("quoted", block_format: TextBlockFormat.new(quote_level: 1)),
    ]
    md = TextMarkdown.generate(blocks)
    md.should eq "<div>x</div>\n\n> quoted"

    round = TextDocument.from_markdown(md)
    # The html block stays intact (not "<div>x</div>\n> quoted") at q0 ...
    html = round.blocks.find! { |b| b.text == "<div>x</div>" }
    html.block_format.quote_level.should eq 0
    # ... and the follower survives as its own quoted block, not a leaked ">".
    quoted = round.blocks.find! { |b| b.text == "quoted" }
    quoted.block_format.quote_level.should eq 1
    round.to_markdown.should eq md
  end

  # The symmetric decrease: an html-blockish block nested inside a quote (q1)
  # followed by a shallower plain paragraph (q0). The follower must survive as
  # its own q0 block rather than being folded back into the quoted html block.
  it "separates a quoted html block from a shallower plain follower" do
    blocks = [
      TextBlock.new("<div>x</div>", block_format: TextBlockFormat.new(quote_level: 1)),
      TextBlock.new("plain"),
    ]
    md = TextMarkdown.generate(blocks)
    md.should eq "> <div>x</div>\n\nplain"

    round = TextDocument.from_markdown(md)
    html = round.blocks.find! { |b| b.text == "<div>x</div>" }
    html.block_format.quote_level.should eq 1
    plain = round.blocks.find! { |b| b.text == "plain" }
    plain.block_format.quote_level.should eq 0
    round.to_markdown.should eq md
  end
end
