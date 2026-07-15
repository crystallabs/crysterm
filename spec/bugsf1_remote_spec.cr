require "./spec_helper"
require "http/client"

# Regression specs for the BUGS-F1 Remote/DOM fixes (findings 24, 25, 43, 44,
# 53, 54, 55). Guarded by -Dremote like the other bridge specs; run with:
#   crystal spec -Dremote spec/bugsf1_remote_spec.cr
{% if flag?(:remote) %}
  include Crysterm

  private def headless_screen
    Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new, width: 80, height: 24)
  end

  private def rgb(name)
    Crysterm::Colors.convert(name).to_i32
  end

  # ---- Finding 24: registry leaf-name collision ----------------------------

  describe "BUGS-F1 #24 <w-progressbar> registry key collision (ProgressBar vs Pine::ProgressBar)" do
    it "registers progressbar to the standard Widget::ProgressBar (shallowest namespace wins)" do
      factory = Crysterm::DOM.registry["progressbar"]?.not_nil!
      w = factory.call(headless_screen)
      # Exact class, not the Pine subclass — before the fix, `all_subclasses`
      # order decided non-deterministically which one shadowed the key.
      w.class.should eq Crysterm::Widget::ProgressBar
    end

    it "loads <w-progressbar> as the standard widget, not the Pine subclass" do
      s = headless_screen
      s.load_layout %(<w-window><w-progressbar id="p"></w-progressbar></w-window>)
      pb = s.find_by_id("p").not_nil!
      pb.class.should eq Crysterm::Widget::ProgressBar
    end
  end

  # ---- Finding 25: top-level append must not wipe inline CSS ----------------

  describe "BUGS-F1 #25 top-level append keeps the page's inline <style> rules" do
    it "a selector-less append of a <style>-less fragment does NOT wipe inline CSS" do
      s = headless_screen
      s.load_layout %(<w-window><style>#x{color:red}</style><w-box id="x"></w-box></w-window>)
      s.apply_stylesheet
      s.find_by_id("x").not_nil!.styles.normal.fg.should eq rgb("red")

      # Mirrors the bridge's selector-less `append` RPC: DOM.load(html, window)
      # with parent = nil and no <style> in the fragment.
      Crysterm::DOM.load(%(<w-box id="y"></w-box>), s)
      s.apply_stylesheet
      # Before the fix, the empty add_inline_stylesheet cleared #x's rule.
      s.find_by_id("x").not_nil!.styles.normal.fg.should eq rgb("red")
    end

    it "a top-level append carrying its own <style> merges rather than replaces" do
      s = headless_screen
      s.load_layout %(<w-window><style>#x{color:red}</style><w-box id="x"></w-box></w-window>)
      Crysterm::DOM.load(%(<style>#y{color:blue}</style><w-box id="y"></w-box>), s)
      s.apply_stylesheet
      s.find_by_id("x").not_nil!.styles.normal.fg.should eq rgb("red")  # kept
      s.find_by_id("y").not_nil!.styles.normal.fg.should eq rgb("blue") # added
    end

    it "load_layout still REPLACES inline CSS (hot-reload semantics preserved)" do
      s = headless_screen
      s.load_layout %(<w-window><style>#x{color:red}</style><w-box id="x"></w-box></w-window>)
      s.load_layout %(<w-window><w-box id="x"></w-box></w-window>) # no <style>
      s.apply_stylesheet
      s.find_by_id("x").not_nil!.styles.normal.fg.should_not eq rgb("red")
    end
  end

  # ---- Finding 43: start/quit server lifecycle -----------------------------

  describe "BUGS-F1 #43 HTTPBridge start/quit server lifecycle" do
    it "does not latch running? when bind fails, and closes the server on quit" do
      a = Crysterm::HTTPBridge.new(headless_screen, port: 7310)
      a.start
      sleep 100.milliseconds # let the listen fiber schedule before we quit it
      a.running?.should be_true

      # Second bridge on the same live port: bind_tcp raises. running? must stay
      # false so a retry is possible (before the fix it latched true BEFORE the
      # bind, permanently no-op'ing every later start in the process).
      b = Crysterm::HTTPBridge.new(headless_screen, port: 7310)
      expect_raises(Socket::BindError) { b.start }
      b.running?.should be_false

      # quit closes the listener socket + fibers and clears running? (before the
      # fix the server was a local var, so quit leaked it).
      a.quit
      a.running?.should be_false

      # The port is reusable now — proof the server was actually closed.
      c = Crysterm::HTTPBridge.new(headless_screen, port: 7310)
      c.start
      c.running?.should be_true
      c.quit
    end
  end

  # ---- Finding 44: JSON-RPC error responses always carry id ----------------

  describe "BUGS-F1 #44 JSON-RPC responses always include id (null on parse error)" do
    it "emits id:null on a parse error" do
      bridge = Crysterm::HTTPBridge.new(headless_screen, port: 7320)
      bridge.start
      sleep 100.milliseconds
      begin
        resp = HTTP::Client.post("http://127.0.0.1:7320/rpc", body: "{ this is not json")
        body = JSON.parse(resp.body)
        body["jsonrpc"].should eq "2.0"
        body.as_h.has_key?("id").should be_true # present...
        body["id"].raw.should be_nil            # ...and null, per JSON-RPC 2.0
        body["error"]["code"].should eq -32_700
      ensure
        bridge.quit
      end
    end

    it "echoes the request id on a normal response" do
      s = headless_screen
      s.load_layout %(<w-window><w-box id="x" content="v"></w-box></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7321)
      bridge.start
      sleep 100.milliseconds
      begin
        resp = HTTP::Client.post("http://127.0.0.1:7321/rpc",
          body: %({"jsonrpc":"2.0","id":7,"method":"getContent","params":{"selector":"#x"}}))
        body = JSON.parse(resp.body)
        body["id"].should eq 7
        body["result"].should eq "v"
      ensure
        bridge.quit
      end
    end
  end

  # ---- Finding 53: bare boolean layout attributes ---------------------------

  describe "BUGS-F1 #53 bare boolean layout attributes parse as true (HTML semantics)" do
    it "treats a valueless / empty parse-tags as true, explicit false as false" do
      box = Widget::Box.new parent: headless_screen, width: 10, height: 3
      box.parse_tags = false
      box.dom_apply "parse-tags", nil # bare boolean attribute
      box.parse_tags?.should be_true
      box.dom_apply "parse-tags", "" # empty value, same semantics
      box.parse_tags?.should be_true
      box.dom_apply "parse-tags", "false"
      box.parse_tags?.should be_false
    end

    it "keeps wrap-content bare == true and explicit false == false" do
      box = Widget::Box.new parent: headless_screen, width: 10, height: 3
      box.dom_apply "wrap-content", nil
      box.wrap_content?.should be_true
      box.dom_apply "wrap-content", "false"
      box.wrap_content?.should be_false
    end

    it "loads a bare <w-box parse-tags> as parse_tags? == true" do
      s = headless_screen
      s.load_layout %(<w-window><w-box id="b" parse-tags></w-box></w-window>)
      s.find_by_id("b").not_nil!.parse_tags?.should be_true
    end

    it "auto-generated bool branch also treats a bare attribute as true" do
      pb = Widget::ProgressBar.new window: headless_screen, width: 20, height: 1
      pb.show_value?.should be_false
      pb.dom_apply "show-text", nil # generated branch (dom_autoserialize.cr)
      pb.show_value?.should be_true
      pb.dom_apply "show-text", "false"
      pb.show_value?.should be_false
    end
  end

  # ---- Finding 54: List#dom_apply("items", "") clears --------------------

  describe %(BUGS-F1 #54 List#dom_apply("items", "") clears instead of adding an empty row) do
    it "leaves the list empty for an empty-string value (no phantom empty row)" do
      list = Widget::List.new parent: headless_screen, width: 10, height: 5
      list.dom_apply "items", "a\nb\nc"
      list.ritems.should eq %w[a b c]

      list.dom_apply "items", "" # bridge client clearing the rows
      list.ritems.should be_empty
      list.children.size.should eq 0
    end
  end

  # ---- Finding 55: SSE /events flushes on connect --------------------------

  describe "BUGS-F1 #55 SSE /events flushes headers on connect" do
    it "delivers the stream open (: connected) immediately, not after the 15s ping" do
      bridge = Crysterm::HTTPBridge.new(headless_screen, port: 7330)
      bridge.start
      sleep 100.milliseconds

      got = Channel(String).new(1)
      spawn do
        HTTP::Client.get("http://127.0.0.1:7330/events") do |response|
          if line = response.body_io.gets
            got.send line
          end
        end
      rescue
        # server closed / client torn down in ensure — ignore
      end

      begin
        select
        when line = got.receive
          # Before the fix, HTTP::Server buffered the headers until the first
          # write, so nothing arrived until an event or the 15s ping.
          line.should contain "connected"
        when timeout(3.seconds)
          fail "no SSE data flushed on connect (headers not flushed until first event/ping)"
        end
      ensure
        bridge.quit
      end
    end
  end
{% end %}
