require "./spec_helper"

include Crysterm

# `Widget::TocView#track`: the sidebar following a reading position, the way
# an IDE outline view highlights the symbol the caret is in.

private MD = "preamble\n\n# Alpha\n\nintro\n\n## Beta\n\nbeta body\n\n# Gamma\n\ngamma body"

# Blocks: 0 preamble, 1 Alpha, 2 intro, 3 Beta, 4 beta body, 5 Gamma,
# 6 gamma body.
private def toc_view(md : String = MD) : Crysterm::Widget::TocView
  s = headless_screen 40, 20
  Crysterm::Widget::TocView.new(
    parent: s, width: 24, height: 20,
    document: Crysterm::TextDocument.from_markdown(md))
end

private def selected(tv : Crysterm::Widget::TocView) : String?
  tv.selected_node.try(&.text)
end

private def pos(tv : Crysterm::Widget::TocView, block : Int32, off : Int32 = 0) : Int32
  tv.document.not_nil!.block_position(block) + off
end

describe "Crysterm::Widget::TocView#track" do
  it "selects the heading a position in the text below it is under" do
    tv = toc_view
    tv.track(pos(tv, 4, 3)).should be_true
    selected(tv).should eq "Beta"
  end

  it "selects a heading for a position on its own line" do
    tv = toc_view
    tv.track(pos(tv, 3)).should be_true
    selected(tv).should eq "Beta"
    tv.track(pos(tv, 5, 2)).should be_true
    selected(tv).should eq "Gamma"
  end

  it "leaves the selection alone for a position above the first heading" do
    tv = toc_view
    tv.track(pos(tv, 6))
    selected(tv).should eq "Gamma"
    tv.track(pos(tv, 0, 2)).should be_false
    selected(tv).should eq "Gamma"
  end

  it "returns false for a document with no outline" do
    tv = toc_view "just a paragraph"
    tv.track(3).should be_false
    tv.selected_node.should be_nil
  end

  it "selects the visible ancestor of an entry hidden by a collapse, without expanding it" do
    tv = toc_view
    alpha = tv.roots.first
    tv.collapse alpha
    tv.nodes.map(&.text).should eq ["Alpha", "Gamma"]
    tv.track(pos(tv, 6)) # park elsewhere first
    tv.track(pos(tv, 4, 3)).should be_true
    selected(tv).should eq "Alpha"
    alpha.expanded?.should be_false
    tv.nodes.map(&.text).should eq ["Alpha", "Gamma"]
  end

  it "emits no AnchorClick" do
    tv = toc_view
    seen = [] of String
    tv.on(Crysterm::Event::AnchorClick) { |e| seen << e.url }
    tv.track(pos(tv, 4))
    tv.track(pos(tv, 6))
    seen.should be_empty
  end

  it "returns false when the selection is already on the entry" do
    tv = toc_view
    tv.track(pos(tv, 4)).should be_true
    tv.track(pos(tv, 4, 2)).should be_false
    selected(tv).should eq "Beta"
  end

  it "keeps the tracked selection across an edit elsewhere" do
    tv = toc_view
    tv.track(pos(tv, 4))
    selected(tv).should eq "Beta"
    doc = tv.document.not_nil!
    # A heading inserted above shifts every row; the selection follows the anchor.
    c = TextCursor.new doc
    c.set_position pos(tv, 0, "preamble".size)
    c.insert_block TextBlockFormat.new(heading_level: 1)
    c.insert_text "Zero"
    tv.nodes.map(&.text).should eq ["Zero", "Alpha", "Beta", "Gamma"]
    selected(tv).should eq "Beta"
  end
end
