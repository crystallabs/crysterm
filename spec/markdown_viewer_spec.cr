require "./spec_helper"

include Crysterm

# The `TocView` + `TextBrowser` composite (`Widget::MarkdownViewer`).

private PAGES = {
  "home"  => "# Intro\n\nbody\n\n## Usage\n\nSee [more](other).",
  "other" => "# Other\n\n## Detail\n\ntext",
}

private def viewer(md : String = PAGES["home"], **opts) : Crysterm::Widget::MarkdownViewer
  s = headless_screen 80, 24
  Crysterm::Widget::MarkdownViewer.new(
    **opts,
    parent: s, width: "100%", height: "100%",
    document: Crysterm::TextDocument.from_markdown(md))
end

private def toc_labels(mv : Crysterm::Widget::MarkdownViewer) : Array(String)
  mv.toc_view.nodes.map(&.text)
end

describe Crysterm::Widget::MarkdownViewer do
  it "shows the same document in both panes" do
    mv = viewer
    mv.browser.document.same?(mv.document).should be_true
    mv.toc_view.document.same?(mv.document).should be_true
    toc_labels(mv).should eq ["Intro", "Usage"]
  end

  it "lays the sidebar out at toc_width" do
    mv = viewer toc_width: 30
    mv.panes.size.should eq 2
    mv.panes.first.same?(mv.toc_view).should be_true
    mv.window?.not_nil!.repaint
    mv.sizes.first.should eq 30
  end

  it "replaces the document in both panes" do
    mv = viewer
    mv.document = TextDocument.from_markdown PAGES["other"]
    toc_labels(mv).should eq ["Other", "Detail"]
  end

  it "jumps the browser to the heading a sidebar entry names" do
    mv = viewer
    mv.toc_view.current_index = 1
    mv.toc_view.activate_current
    doc = mv.document
    doc.blocks[doc.block_at(mv.browser.cursor_pos).index].text.should eq "Usage"
  end

  it "re-points the sidebar when a followed link loads a new page" do
    mv = viewer
    mv.loader = ->(url : String) { PAGES[url]?.try { |md| TextDocument.from_markdown(md) } }
    mv.browser.activate_link "other"
    toc_labels(mv).should eq ["Other", "Detail"]
    mv.toc_view.document.same?(mv.browser.document).should be_true
  end

  it "keeps the sidebar's document across a same-document jump" do
    mv = viewer
    tv_doc = mv.toc_view.document
    mv.browser.activate_link "#usage"
    mv.toc_view.document.same?(tv_doc).should be_true
  end

  describe "#show_toc" do
    it "starts without the sidebar when built with show_toc: false" do
      mv = viewer show_toc: false
      mv.panes.size.should eq 1
      mv.panes.first.same?(mv.browser).should be_true
    end

    it "hides and re-shows the sidebar" do
      mv = viewer
      mv.show_toc = false
      mv.panes.size.should eq 1
      mv.show_toc = true
      mv.panes.size.should eq 2
      mv.panes.first.same?(mv.toc_view).should be_true
    end

    it "keeps tracking the document while hidden" do
      mv = viewer
      mv.show_toc = false
      mv.document = TextDocument.from_markdown PAGES["other"]
      mv.show_toc = true
      toc_labels(mv).should eq ["Other", "Detail"]
    end
  end
end
