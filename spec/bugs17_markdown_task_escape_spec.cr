require "./spec_helper"

include Crysterm

# Regression spec for BUGS17 B17-31 — the markdown importer classified a
# backslash-escaped `\[x\]` item as a GFM task marker (markd resolves the
# escape before the AST, so its text nodes are identical to a real `[x]`),
# turning a literal `[x]` bullet into a checked checkbox item and deleting the
# leading 4 chars. The fix consults each item's source position to tell an
# escaped `[` from a real one.
describe "BUGS17 escaped task marker" do
  # An escaped `\[x\]` bullet is literal text, not a task item.
  it "keeps an escaped [x] bullet as a plain disc item" do
    doc = TextDocument.from_markdown("- \\[x\\] a")
    lf = doc.blocks[0].block_format.list_format
    lf.should_not be_nil
    lf.not_nil!.style.disc?.should be_true
    doc.blocks[0].text.should eq "[x] a"
    doc.blocks[0].block_format.checked?.should be_false
  end

  # The HTML->markdown->document round-trip of a literal `[x]` bullet must
  # preserve both the disc style and the text (the exporter escapes it, and
  # re-import must honor the escape).
  it "round-trips a literal [x] disc item without style or text loss" do
    doc = TextDocument.from_html("<ul><li>[x] foo</li></ul>")
    round = TextDocument.from_markdown(doc.to_markdown)
    lf = round.blocks[0].block_format.list_format
    lf.should_not be_nil
    lf.not_nil!.style.disc?.should be_true
    round.blocks[0].text.should eq "[x] foo"
    round.blocks[0].block_format.checked?.should be_false
  end

  # Guard against over-rejection: a real (unescaped) task list still becomes a
  # checkbox list with its items' checked state and stripped marker text.
  it "still recognizes real task-list markers" do
    doc = TextDocument.from_markdown("- [x] a\n- [ ] b")
    lf = doc.blocks[0].block_format.list_format
    lf.not_nil!.style.checkbox?.should be_true
    doc.blocks[0].text.should eq "a"
    doc.blocks[0].block_format.checked?.should be_true
    doc.blocks[1].text.should eq "b"
    doc.blocks[1].block_format.checked?.should be_false
  end
end
