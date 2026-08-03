require "./spec_helper"

include Crysterm

# The sidebar outline (`Widget::TocView`). Unlike the inline
# `TextToc` it tracks the document live: rebuilding it reflows nothing.

private def toc_view(md : String) : Crysterm::Widget::TocView
  s = headless_screen 40, 20
  Crysterm::Widget::TocView.new(
    parent: s, width: 24, height: 20,
    document: Crysterm::TextDocument.from_markdown(md))
end

private def labels(tv : Crysterm::Widget::TocView) : Array(String)
  tv.nodes.map(&.text)
end

describe Crysterm::Widget::TocView do
  it "lists the document's headings" do
    tv = toc_view "# One\n\n## Two\n\n# Three"
    labels(tv).should eq ["One", "Two", "Three"]
  end

  it "nests entries by heading level" do
    tv = toc_view "# One\n\n## Two"
    tv.roots.size.should eq 1
    tv.roots.first.text.should eq "One"
    tv.roots.first.children.map(&.text).should eq ["Two"]
  end

  it "carries the anchor as node data" do
    tv = toc_view "# Getting Started"
    tv.roots.first.data.should eq "getting-started"
  end

  it "measures depth from the shallowest heading present" do
    tv = toc_view "## Two\n\n### Three"
    # No empty placeholder root just because the document starts at h2.
    tv.roots.map(&.text).should eq ["Two"]
    tv.roots.first.children.map(&.text).should eq ["Three"]
  end

  it "inserts a filler node for a skipped level" do
    tv = toc_view "# One\n\n### Three"
    tv.roots.first.children.map(&.text).should eq ["##"]
    tv.roots.first.children.first.children.map(&.text).should eq ["Three"]
    tv.roots.first.children.first.data.should be_nil
  end

  it "is empty for a document with no headings" do
    tv = toc_view "just a paragraph"
    tv.roots.should be_empty
  end

  describe "live tracking" do
    it "follows a heading appended to the document" do
      tv = toc_view "# One"
      labels(tv).should eq ["One"]
      doc = tv.document.not_nil!
      c = TextCursor.new doc
      c.set_position doc.size
      c.insert_block TextBlockFormat.new(heading_level: 2)
      c.insert_text "Two"
      labels(tv).should eq ["One", "Two"]
    end

    it "rebuilds nothing when an edit leaves the outline alone" do
      tv = toc_view "# One\n\nbody"
      root = tv.roots.first
      doc = tv.document.not_nil!
      doc.insert_text(doc.size, "!")
      tv.roots.first.should be root
    end

    it "preserves collapsed state by anchor across a rebuild" do
      tv = toc_view "# One\n\n## Two\n\n# Later"
      tv.roots.first.expanded = false
      labels(tv).should eq ["One", "Later"]
      doc = tv.document.not_nil!
      c = TextCursor.new doc
      c.set_position doc.size
      c.insert_block TextBlockFormat.new(heading_level: 1)
      c.insert_text "Newest"
      labels(tv).should eq ["One", "Later", "Newest"]
    end

    it "preserves the selection by anchor across a rebuild" do
      tv = toc_view "# One\n\n# Two"
      tv.current_index = 1
      tv.selected_node.try(&.text).should eq "Two"
      doc = tv.document.not_nil!
      # A heading inserted *above* shifts every row; the anchor does not.
      c = TextCursor.new doc
      c.set_position 0
      c.insert_block TextBlockFormat.new(heading_level: 1)
      c.set_position 0
      c.insert_text "Zero"
      tv.selected_node.try(&.text).should eq "Two"
    end

    it "detaches from a replaced document" do
      tv = toc_view "# One"
      old = tv.document.not_nil!
      tv.document = TextDocument.from_markdown "# Other"
      labels(tv).should eq ["Other"]
      old.insert_text(old.size, " more")
      labels(tv).should eq ["Other"]
    end

    it "empties when detached" do
      tv = toc_view "# One"
      tv.document = nil
      tv.roots.should be_empty
    end
  end

  describe "activation" do
    it "emits AnchorClick carrying the entry's anchor" do
      tv = toc_view "# One\n\n# Two"
      seen = [] of String
      tv.on(Crysterm::Event::AnchorClick) { |e| seen << e.url }
      tv.current_index = 1
      tv.activate_current
      seen.should eq ["#two"]
    end

    it "drives a TextBrowser to the heading" do
      doc = TextDocument.from_markdown "# Intro\n\nbody\n\n## Usage\n\nmore"
      s = headless_screen 60, 20
      tb = Widget::TextBrowser.new(parent: s, width: 40, height: 20)
      tb.document = doc
      tv = Widget::TocView.new(parent: s, width: 20, height: 20, document: doc)
      tv.on(Crysterm::Event::AnchorClick) { |e| tb.activate_link e.url }
      tv.current_index = 1
      tv.activate_current
      doc.blocks[doc.block_at(tb.cursor_pos)[0]].text.should eq "Usage"
    end
  end

  describe "CSS" do
    it "exposes the item sub-control" do
      toc_view("# One").build_css_sub_elements.should contain "item"
    end
  end
end
