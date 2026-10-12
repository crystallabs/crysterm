require "./spec_helper"

include Crysterm

# A `TextEdit` block image from a URL across a whole-content replacement: a
# measured size stays (`Media.decode` holds the URL's picture), while a URL
# that could not be fetched is measured again — `Media.decode` remembers
# that failure only for `Media.remote_failure_ttl`, so a network blip must
# not keep the picture out of the view for the rest of the process.

private def headless_screen(w = 40, h = 8)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# Runs the block with a fetcher that reaches no network and fails.
private def without_network(&)
  previous = Widget::Media.fetcher
  begin
    Widget::Media.fetcher = ->(_u : String) : Bytes { raise "offline" }
    yield
  ensure
    Widget::Media.fetcher = previous
    Widget::Media.clear_decode_cache
  end
end

describe "TextEdit block images from a URL" do
  it "measures a URL that failed again after a whole-content replacement, and keeps one that was measured" do
    without_network do
      s = headless_screen
      tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: s.awidth, height: s.aheight
      failed = "https://example.invalid/blip.png"
      measured = "https://example.invalid/pic.png"
      tb.set_markdown "![f](#{failed})\n\n![m](#{measured})"
      # As the fetch fibers would have left them: one failed, one measured.
      tb.@image_sizes[failed] = nil
      tb.@image_sizes[measured] = {240, 84}

      tb.set_markdown "![f](#{failed})\n\n![m](#{measured})\n\nmore"
      tb.@image_sizes.has_key?(failed).should be_false
      tb.@image_sizes[measured]?.should eq({240, 84})
      s.repaint
      # The failed URL is being fetched again; the measured one is not.
      tb.@image_loading.should eq Set{failed}
      s.destroy
    end
  end
end
