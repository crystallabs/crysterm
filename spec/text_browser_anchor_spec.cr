require "./spec_helper"

include Crysterm

# Same-document anchor navigation in `TextBrowser`. Without
# this, `[x](#install)` — and every link a `TextToc` generates — was handed to
# the loader whole and went nowhere.

private def browser(md : String) : Crysterm::Widget::TextBrowser
  s = headless_screen 40, 10
  tb = Crysterm::Widget::TextBrowser.new(parent: s, width: 40, height: 10)
  tb.document = Crysterm::TextDocument.from_markdown md
  tb
end

private LONG_DOC = <<-MD
  # Intro

  body one

  ## Install

  body two

  ## Usage

  body three
  MD

describe Crysterm::Widget::TextBrowser do
  describe ".sanitize_location" do
    it "splits a path from its fragment" do
      Widget::TextBrowser.sanitize_location("guide.md#install").should eq({"guide.md", "install"})
    end

    it "handles a bare fragment" do
      Widget::TextBrowser.sanitize_location("#install").should eq({"", "install"})
    end

    it "handles a path with no fragment" do
      Widget::TextBrowser.sanitize_location("guide.md").should eq({"guide.md", ""})
    end

    it "splits on the first # only" do
      Widget::TextBrowser.sanitize_location("a#b#c").should eq({"a", "b#c"})
    end
  end

  describe "#goto_anchor" do
    it "moves the caret to the matching heading" do
      tb = browser LONG_DOC
      tb.goto_anchor("install").should be_true
      tb.document.block_at(tb.cursor_pos)[0].should eq tb.document.outline[1].block
    end

    it "accepts a leading hash" do
      tb = browser LONG_DOC
      tb.goto_anchor("#usage").should be_true
      tb.document.blocks[tb.document.block_at(tb.cursor_pos)[0]].text.should eq "Usage"
    end

    it "returns false for an unknown anchor" do
      tb = browser LONG_DOC
      tb.goto_anchor("nope").should be_false
    end

    it "returns false for an empty anchor" do
      browser(LONG_DOC).goto_anchor("#").should be_false
    end

    it "resolves a percent-encoded anchor" do
      tb = browser "# Über\n\nbody"
      tb.goto_anchor("%C3%BCber").should be_true
    end
  end

  describe "#source= with a fragment" do
    it "jumps within the current document without consulting the loader" do
      tb = browser LONG_DOC
      calls = 0
      tb.loader = ->(_u : String) { calls += 1; nil.as(TextDocument?) }
      tb.source = "#usage"
      calls.should eq 0
      tb.document.blocks[tb.document.block_at(tb.cursor_pos)[0]].text.should eq "Usage"
    end

    it "loads a path and then resolves the fragment" do
      tb = browser "# Placeholder"
      tb.loader = ->(url : String) do
        url.should eq "guide.md"
        TextDocument.from_markdown(LONG_DOC).as(TextDocument?)
      end
      tb.source = "guide.md#usage"
      tb.document.blocks[tb.document.block_at(tb.cursor_pos)[0]].text.should eq "Usage"
    end

    it "does not reload when only the fragment changes" do
      tb = browser "# Placeholder"
      loads = 0
      tb.loader = ->(_u : String) do
        loads += 1
        TextDocument.from_markdown(LONG_DOC).as(TextDocument?)
      end
      tb.source = "guide.md#install"
      tb.source = "guide.md#usage"
      loads.should eq 1
    end

    it "activates a TOC link" do
      doc = TextDocument.from_markdown "[TOC]\n\n#{LONG_DOC}"
      s = headless_screen 40, 10
      tb = Widget::TextBrowser.new(parent: s, width: 40, height: 10)
      tb.document = doc
      url = doc.tocs.first.blocks.last.fragments.first.format.anchor_href
      url.should eq "#usage"
      tb.activate_link url.not_nil!
      tb.document.blocks[tb.document.block_at(tb.cursor_pos)[0]].text.should eq "Usage"
    end
  end

  describe "history" do
    it "records an in-document jump and restores the reading position" do
      tb = browser LONG_DOC
      tb.source = "#install"
      here = tb.cursor_pos
      tb.source = "#usage"
      tb.backward_available?.should be_true
      tb.backward.should be_true
      tb.cursor_pos.should eq here
      tb.source.should eq "#install"
    end

    it "goes forward again" do
      tb = browser LONG_DOC
      tb.source = "#install"
      tb.source = "#usage"
      there = tb.cursor_pos
      tb.backward.should be_true
      tb.forward.should be_true
      tb.cursor_pos.should eq there
    end

    it "leaves everything unchanged when the loader declines" do
      tb = browser "# Only"
      tb.loader = ->(_u : String) { nil.as(TextDocument?) }
      tb.source = "missing.md"
      tb.source.should be_nil
      tb.backward_available?.should be_false
      tb.document.blocks.first.text.should eq "Only"
    end
  end
end
