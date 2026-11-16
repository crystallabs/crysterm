require "./spec_helper"
require "socket"

private R3_URL = "http://media.invalid/pic.png"

private def r3_png : Bytes
  PNGGIF.encode_png(Array.new(2) { Array.new(2) { PNGGIF::Pixel.new(200, 100, 50) } })
end

# Runs the block with *fetcher* standing in for the network, putting it, the
# `media.remote_fetch` option and the decode cache back after.
private def r3_with_fetcher(fetcher : Proc(String, Bytes), &)
  previous = Crysterm::Widget::Media.fetcher
  allowed = Crysterm::Config.media_remote_fetch
  begin
    Crysterm::Widget::Media.fetcher = fetcher
    yield
  ensure
    Crysterm::Widget::Media.fetcher = previous
    Crysterm::Config.media_remote_fetch = allowed
    Crysterm::Widget::Media.clear_decode_cache
  end
end

describe "Media file= supplied by markup" do
  it "refuses an http(s) URL unless media.remote_fetch is set" do
    fetched = [] of String
    r3_with_fetcher(->(u : String) : Bytes { fetched << u; r3_png }) do
      s = headless_screen(20, 6)
      begin
        img = Crysterm::Widget::Media::Ansi.new parent: s, width: 4, height: 2
        img.dom_apply("file", R3_URL).should be_true
        img.remote_refused?.should be_true
        img.remote_pending?.should be_false
        img.file.should eq R3_URL
        img.content.should contain "could not load"
        s.repaint
        Fiber.yield
        fetched.should be_empty
      ensure
        s.destroy
      end
    end
  end

  it "refuses it on an in-band graphics backend too" do
    fetched = [] of String
    r3_with_fetcher(->(u : String) : Bytes { fetched << u; r3_png }) do
      s = headless_screen(20, 6)
      begin
        [Crysterm::Widget::Media::Sixel.new(parent: s, width: 4, height: 2),
         Crysterm::Widget::Media::Iterm.new(parent: s, width: 4, height: 2)].each do |img|
          img.dom_apply("file", "https://media.invalid/a.png").should be_true
          img.remote_refused?.should be_true
        end
        s.repaint
        Fiber.yield
        fetched.should be_empty
      ensure
        s.destroy
      end
    end
  end

  it "refuses it in a loaded layout document" do
    fetched = [] of String
    r3_with_fetcher(->(u : String) : Bytes { fetched << u; r3_png }) do
      s = headless_screen(20, 6)
      begin
        built = s.load_layout %(<w-window><w-sixel file="#{R3_URL}" width="4" height="2"></w-sixel></w-window>)
        built.size.should eq 1
        img = built[0].as(Crysterm::Widget::Media::Base)
        img.remote_refused?.should be_true
        img.file.should eq R3_URL
        s.repaint
        Fiber.yield
        fetched.should be_empty
      ensure
        s.destroy
      end
    end
  end

  it "fetches it once media.remote_fetch is set" do
    fetched = [] of String
    r3_with_fetcher(->(u : String) : Bytes { fetched << u; r3_png }) do
      Crysterm::Config.media_remote_fetch = true
      s = headless_screen(20, 6)
      begin
        img = Crysterm::Widget::Media::Ansi.new parent: s, width: 4, height: 2
        img.dom_apply("file", R3_URL).should be_true
        img.remote_refused?.should be_false
        wait_until { !img.remote_pending? }
        fetched.should eq [R3_URL]
        img.content.should_not contain "could not load"
      ensure
        s.destroy
      end
    end
  end

  it "leaves a local path alone" do
    r3_with_fetcher(->(_u : String) : Bytes { raise "no network" }) do
      s = headless_screen(20, 6)
      begin
        img = Crysterm::Widget::Media::Sixel.new parent: s, width: 4, height: 2
        img.dom_apply("file", "some/local.png").should be_true
        img.remote_refused?.should be_false
        img.remote_pending?.should be_false
        img.file.should eq "some/local.png"
      ensure
        s.destroy
      end
    end
  end
end

describe "Media#file= with an http(s) URL set by the application" do
  it "is allowed without the option, and neither the caller nor a frame waits for the download" do
    fetched = [] of String
    gate = Channel(Nil).new
    r3_with_fetcher(->(u : String) : Bytes { fetched << u; gate.receive; r3_png }) do
      s = headless_screen(20, 6)
      begin
        img = Crysterm::Widget::Media::Ansi.new parent: s, width: 4, height: 2
        img.file = R3_URL
        img.remote_refused?.should be_false
        img.remote_pending?.should be_true
        s.repaint
        Fiber.yield
        img.remote_pending?.should be_true
        fetched.should eq [R3_URL]

        gate.send nil
        wait_until { !img.remote_pending? }
        img.content.should_not contain "could not load"
        s.repaint
        fetched.should eq [R3_URL]
      ensure
        s.destroy
      end
    end
  end

  it "takes the failed-load path when the download fails" do
    r3_with_fetcher(->(_u : String) : Bytes { raise "offline" }) do
      s = headless_screen(20, 6)
      begin
        img = Crysterm::Widget::Media::Ansi.new parent: s, width: 4, height: 2
        img.load R3_URL
        wait_until { !img.remote_pending? }
        img.content.should contain "could not load"
        img.file.should eq R3_URL
      ensure
        s.destroy
      end
    end
  end

  it "drops a download its widget no longer wants" do
    gate = Channel(Nil).new
    r3_with_fetcher(->(_u : String) : Bytes { gate.receive; r3_png }) do
      s = headless_screen(20, 6)
      begin
        img = Crysterm::Widget::Media::Ansi.new parent: s, width: 4, height: 2
        img.file = R3_URL
        Fiber.yield
        img.clear_image
        img.remote_pending?.should be_false
        gate.send nil
        3.times { Fiber.yield }
        img.file.nil?.should be_true
        img.content.should_not contain "could not load"
      ensure
        s.destroy
      end
    end
  end

  it "fetches a URL given to an in-band graphics constructor off the render fiber, once" do
    fetched = [] of String
    gate = Channel(Nil).new
    r3_with_fetcher(->(u : String) : Bytes { fetched << u; gate.receive; r3_png }) do
      s = headless_screen(20, 6)
      begin
        imgs = [Crysterm::Widget::Media::Sixel.new(parent: s, file: R3_URL, width: 4, height: 2),
                Crysterm::Widget::Media::Iterm.new(parent: s, file: R3_URL, top: 3, width: 4, height: 2)]
        imgs.each(&.remote_pending?.should(be_true))
        s.repaint
        Fiber.yield
        s.repaint
        # Both widgets wait on the one download.
        fetched.should eq [R3_URL]

        gate.send nil
        wait_until { imgs.none?(&.remote_pending?) }
        s.repaint
        s.repaint
        fetched.should eq [R3_URL]
      ensure
        s.destroy
      end
    end
  end
end

describe "Media.fetch_with_downloader" do
  it "gives up on a host that accepts and never answers" do
    next unless Process.find_executable("curl") || Process.find_executable("wget")
    server = TCPServer.new("127.0.0.1", 0)
    held = [] of TCPSocket
    spawn do
      while client = server.accept?
        held << client
      end
    end
    connect = Crysterm::Widget::Media.fetch_connect_timeout
    total = Crysterm::Widget::Media.fetch_timeout
    begin
      Crysterm::Widget::Media.fetch_connect_timeout = 1.second
      Crysterm::Widget::Media.fetch_timeout = 300.milliseconds
      started = Time.instant
      expect_raises(Exception, "curl or wget failed.") do
        Crysterm::Widget::Media.fetch_with_downloader "http://127.0.0.1:#{server.local_address.port}/x.png"
      end
      (Time.instant - started).should be < 10.seconds
    ensure
      Crysterm::Widget::Media.fetch_connect_timeout = connect
      Crysterm::Widget::Media.fetch_timeout = total
      held.each(&.close)
      server.close
    end
  end
end

describe "A media source over the decoder's pixel limit" do
  it "is a failed load, not an exception" do
    io = IO::Memory.new
    io.write PNGGIF::PNG_SIGNATURE.to_slice
    ihdr = IO::Memory.new
    ihdr.write_bytes 40_000_u32, IO::ByteFormat::BigEndian
    ihdr.write_bytes 40_000_u32, IO::ByteFormat::BigEndian
    ihdr.write Bytes[8, 6, 0, 0, 0]
    idat = IO::Memory.new
    Compress::Zlib::Writer.open(idat, &.write(Bytes[0, 0]))
    [{"IHDR", ihdr.to_slice}, {"IDAT", idat.to_slice}, {"IEND", Bytes.empty}].each do |(type, data)|
      io.write_bytes data.size.to_u32, IO::ByteFormat::BigEndian
      io << type
      io.write data
      io.write_bytes 0_u32, IO::ByteFormat::BigEndian
    end
    path = File.tempname("r3_huge", ".png")
    File.write path, io.to_slice
    s = headless_screen(20, 6)
    begin
      Crysterm::Widget::Media.decode(path).nil?.should be_true
      img = Crysterm::Widget::Media::Ansi.new parent: s, file: path, width: 4, height: 2
      img.content.should contain "could not load"
      sixel = Crysterm::Widget::Media::Sixel.new parent: s, file: path, top: 3, width: 4, height: 2
      s.repaint
      sixel.file.should eq path
    ensure
      s.destroy
      File.delete? path
      Crysterm::Widget::Media.clear_decode_cache
    end
  end
end
