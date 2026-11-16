require "./spec_helper"
require "http/client"

private def b20_window(w = 40, h = 12)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: w, height: h)
end

private class B20ItermProbe < Crysterm::Widget::Media::Iterm
  def probe_last_drawn
    @last_drawn
  end

  def probe_payload
    @payload
  end
end

private class B20KittyProbe < Crysterm::Widget::Media::Kitty
  getter cleared_count = 0

  def probe_last_drawn
    @last_drawn
  end

  protected def graphic_cleared(s : ::Crysterm::Window)
    @cleared_count += 1
    super
  end
end

private class B20SixelProbe < Crysterm::Widget::Media::Sixel
  getter encodes = 0

  def probe_last_drawn
    @last_drawn
  end

  def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32,
             cols : Int32, rows : Int32) : String
    @encodes += 1
    super
  end
end

private class B20RegisProbe < Crysterm::Widget::Media::Regis
  getter encodes = 0

  def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32,
             cols : Int32, rows : Int32) : String
    @encodes += 1
    super
  end
end

describe Crysterm::Widget::Media::Iterm do
  it "draws a bitmap injected with #bitmap=, which has no file to transmit" do
    s = b20_window
    img = B20ItermProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    img.bitmap = bitmap(4, 4, 200, 100, 50)
    s.repaint

    payload = img.probe_payload
    payload.nil?.should be_false
    payload.not_nil!.starts_with?("\e]1337;File=inline=1").should be_true
    img.probe_last_drawn.nil?.should be_false
  ensure
    s.try &.destroy
  end
end

describe Crysterm::Widget::Media::Graphics do
  describe "#load over a painted picture" do
    it "has a cell-drawn backend's old picture erased at once" do
      s = b20_window
      img = B20SixelProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
      img.bitmap = bitmap(4, 4, 200, 100, 50)
      s.repaint
      img.probe_last_drawn.nil?.should be_false

      img.load "data/image/matterhorn.png"
      img.probe_last_drawn.nil?.should be_true
    ensure
      s.try &.destroy
    end

    it "keeps a separate-layer picture up until the new one replaces it" do
      s = b20_window
      img = B20KittyProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
      img.bitmap = bitmap(4, 4, 200, 100, 50)
      s.repaint
      img.probe_last_drawn.nil?.should be_false

      img.load "data/image/matterhorn.png"
      img.probe_last_drawn.nil?.should be_false
      img.cleared_count.should eq 0
    ensure
      s.try &.destroy
    end

    it "takes a separate-layer picture down when the new source fails to load" do
      s = b20_window
      img = B20KittyProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
      img.bitmap = bitmap(4, 4, 200, 100, 50)
      s.repaint
      img.probe_last_drawn.nil?.should be_false

      img.load "/nonexistent/bugs20-missing.png"
      s.repaint
      img.cleared_count.should be >= 1
      img.probe_last_drawn.nil?.should be_true
    ensure
      s.try &.destroy
    end
  end

  describe "moving a picture" do
    it "re-emits a cursor-placed payload without encoding it again" do
      s = b20_window
      img = B20SixelProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
      img.bitmap = bitmap(4, 4, 200, 100, 50)
      s.repaint
      before = img.encodes
      before.should be > 0

      img.left = 3
      s.repaint
      img.encodes.should eq before
      img.probe_last_drawn.not_nil![0].should eq 3
    ensure
      s.try &.destroy
    end

    it "encodes again for a backend whose payload carries the origin" do
      s = b20_window
      img = B20RegisProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
      img.bitmap = bitmap(4, 4, 200, 100, 50)
      s.repaint
      before = img.encodes
      before.should be > 0

      img.left = 3
      s.repaint
      img.encodes.should be > before
    ensure
      s.try &.destroy
    end
  end
end

{% if flag?(:remote) %}
  private def b20_wait_for_bind(port : Int32)
    wait_until do
      TCPSocket.new("127.0.0.1", port).close
      true
    rescue
      false
    end
  end

  describe Crysterm::HTTPBridge do
    it "ends the open /events streams on quit" do
      s = headless_screen(80, 24)
      bridge = Crysterm::HTTPBridge.new(s, port: 7495)
      bridge.start
      b20_wait_for_bind 7495

      subscribed = false
      ended = false
      spawn do
        HTTP::Client.get("http://127.0.0.1:7495/events") do |response|
          while response.body_io.gets
            subscribed = true # `: connected` is flushed once the stream is registered
          end
        end
        ended = true
      rescue
        ended = true
      end

      begin
        wait_until { subscribed }
        bridge.quit
        wait_until { ended }
      ensure
        bridge.quit
      end
    end

    it "answers a request whose job was dropped with the destroyed window" do
      s = headless_screen(80, 24)
      s.load_layout %(<w-window><w-box id="b20" content="hi"></w-box></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7496)
      bridge.start
      b20_wait_for_bind 7496

      # Park the render fiber inside a job, so the request's own job queues
      # behind it and is still queued when the window goes.
      gate = Channel(Nil).new
      s.post do
        gate.receive?
        nil
      end

      answer = Channel(String).new(1)
      spawn do
        response = HTTP::Client.post("http://127.0.0.1:7496/rpc",
          body: %({"jsonrpc":"2.0","id":1,"method":"getContent","params":{"selector":"#b20"}}))
        answer.send response.body
      rescue ex
        answer.send "client error: #{ex.message}"
      end

      begin
        select
        when early = answer.receive
          fail "answered while the render fiber was parked: #{early}"
        when timeout(150.milliseconds)
          # Still waiting on its job, as it must be.
        end

        s.destroy
        gate.close

        select
        when body = answer.receive
          body.should contain "window is destroyed"
        when timeout(2.seconds)
          fail "the request never got an answer"
        end
      ensure
        gate.close
        bridge.quit
      end
    end
  end
{% end %}
