require "./spec_helper"

include Crysterm

# `Widget::Media.decode`'s memory of failed remote URLs is bounded like the
# decode cache itself: a long-running program meeting ever new broken links
# (a chat transcript, a feed) keeps a capped number of them, not every URL it
# ever failed on.
describe "Widget::Media.decode's remote failures" do
  it "keeps at most Cache::IMAGE_DECODE_CAPACITY failed URLs" do
    previous = Widget::Media.fetcher
    begin
      Widget::Media.fetcher = ->(_u : String) : Bytes { raise "unreachable" }
      (Cache::IMAGE_DECODE_CAPACITY * 3).times do |i|
        Widget::Media.decode("http://example.invalid/#{i}.png").should be_nil
      end
      stat = Cache.stats.find { |c| c[:name] == "image_remote_failures" }
      stat.should_not be_nil
      stat.not_nil![:size].should be <= Cache::IMAGE_DECODE_CAPACITY
    ensure
      Widget::Media.fetcher = previous
      Widget::Media.clear_decode_cache
    end
  end
end
