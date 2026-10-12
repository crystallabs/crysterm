require "./spec_helper"

include Crysterm

# `Widget::Media.decode` of a URL: a failed fetch is remembered for
# `Media.remote_failure_ttl` — not fetched again every frame — and tried once
# more when that has passed, where a local file's failure is cached for good
# under its size and mtime. A success is cached as a local file's is.

# A 1×1 PNG.
private PNG_1X1 = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")

# Runs the block with *fetcher* standing in for the network and *ttl* as the
# failure memory, putting both back and emptying the decode cache after.
private def with_fetcher(fetcher : Proc(String, Bytes), ttl : Time::Span, &)
  previous = Widget::Media.fetcher
  previous_ttl = Widget::Media.remote_failure_ttl
  begin
    Widget::Media.fetcher = fetcher
    Widget::Media.remote_failure_ttl = ttl
    yield
  ensure
    Widget::Media.fetcher = previous
    Widget::Media.remote_failure_ttl = previous_ttl
    Widget::Media.clear_decode_cache
  end
end

describe "Widget::Media.decode on a URL" do
  it "remembers a failed fetch for the TTL, then fetches again" do
    url = "http://example.invalid/missing.png"
    attempts = 0
    with_fetcher(->(_u : String) : Bytes { attempts += 1; raise "unreachable" }, 10.seconds) do
      Widget::Media.decode(url).should be_nil
      Widget::Media.decode(url).should be_nil
      attempts.should eq 1 # the failure is remembered, not retried per frame

      Widget::Media.remote_failure_ttl = Time::Span.zero
      Widget::Media.decode(url).should be_nil
      attempts.should eq 2 # the TTL passed: tried again
    end
  end

  it "caches a success and does not fetch again" do
    url = "http://example.invalid/present.png"
    attempts = 0
    with_fetcher(->(_u : String) : Bytes { attempts += 1; PNG_1X1 }, 10.seconds) do
      first = Widget::Media.decode(url)
      first.should be_a PNGGIF::PNG
      Widget::Media.decode(url).should be first
      attempts.should eq 1
    end
  end

  it "forgets the remembered failures with the decode cache" do
    url = "http://example.invalid/gone.png"
    attempts = 0
    with_fetcher(->(_u : String) : Bytes { attempts += 1; raise "unreachable" }, 10.seconds) do
      Widget::Media.decode(url).should be_nil
      Widget::Media.clear_decode_cache
      Widget::Media.decode(url).should be_nil
      attempts.should eq 2
    end
  end
end
