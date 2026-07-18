require "./spec_helper"
require "http/client"

{% if flag?(:remote) %}
  include Crysterm

  # End-to-end test of the HTTP/JSON-RPC bridge, headless: drive a real
  # (memory-backed) screen over HTTP — commands in via POST /rpc, events out via
  # the SSE stream — in-process so it can assert.

  private def headless_screen
    Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
  end

  describe "HTTPBridge" do
    it "applies rpc commands and streams named-action events" do
      s = headless_screen
      s.load_layout %(<w-window>) +
                    %(<w-box id="status" content="hi"></w-box>) +
                    %(<w-button id="ok" onclick="save"></w-button>) +
                    %(</w-window>)

      Crysterm::HTTPBridge.new(s, port: 7099).start
      sleep 100.milliseconds # let the server bind
      base = "http://127.0.0.1:7099"

      # --- command + getter round-trip over POST /rpc ---
      HTTP::Client.post("#{base}/rpc",
        body: %({"jsonrpc":"2.0","method":"setContent","params":{"selector":"#status","value":"changed"}}))

      got = HTTP::Client.post("#{base}/rpc",
        body: %({"jsonrpc":"2.0","id":1,"method":"getContent","params":{"selector":"#status"}}))
      result = JSON.parse(got.body)
      result["id"].as_i.should eq 1
      result["result"].as_s.should eq "changed"

      # --- event stream over GET /events ---
      events = Channel(String).new
      spawn do
        HTTP::Client.get("#{base}/events") do |response|
          while line = response.body_io.gets
            if line.starts_with?("data: ")
              events.send line["data: ".size..]
              break
            end
          end
        end
      end
      sleep 100.milliseconds # ensure the SSE subscription is registered

      # Activating the button (here: emit its Press directly) must surface as a
      # JSON-RPC `event` notification carrying the declared action + target.
      s.find_by_id("ok").not_nil!.emit Crysterm::Event::Pressed

      select
      when msg = events.receive
        params = JSON.parse(msg)
        params["method"].as_s.should eq "event"
        params["params"]["type"].as_s.should eq "press"
        params["params"]["action"].as_s.should eq "save"
        params["params"]["target"].as_s.should eq "#ok"
      when timeout(2.seconds)
        fail "no SSE event received"
      end
    end

    it "applies a command to every match of a general selector" do
      s = headless_screen
      s.load_layout %(<w-window>) +
                    %(<w-button id="a" class="primary"></w-button>) +
                    %(<w-button id="b" class="primary"></w-button>) +
                    %(</w-window>)
      Crysterm::HTTPBridge.new(s, port: 7100).start
      sleep 100.milliseconds

      HTTP::Client.post("http://127.0.0.1:7100/rpc",
        body: %({"jsonrpc":"2.0","method":"addClass","params":{"selector":".primary","class":"hot"}}))

      got = HTTP::Client.post("http://127.0.0.1:7100/rpc",
        body: %({"jsonrpc":"2.0","id":1,"method":"query","params":{"selector":".hot"}}))
      JSON.parse(got.body)["result"].as_a.map(&.as_s).sort.should eq ["#a", "#b"]
    end

    it "enforces a bearer token when configured" do
      s = headless_screen
      s.load_layout %(<w-window><w-box id="x"></w-box></w-window>)
      Crysterm::HTTPBridge.new(s, port: 7101, token: "s3cret").start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7101/rpc"
      body = %({"jsonrpc":"2.0","method":"render"})

      HTTP::Client.post(base, body: body).status_code.should eq 401
      ok = HTTP::Client.post(base, headers: HTTP::Headers{"X-Crysterm-Token" => "s3cret"}, body: body)
      ok.status_code.should eq 200
    end

    it "hot-reloads the whole layout" do
      s = headless_screen
      s.load_layout %(<w-window><w-box id="status" content="v1"></w-box></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7102)
      bridge.start

      s.find_by_id("status").not_nil!.content.should eq "v1"
      bridge.reload_layout %(<w-window><w-box id="status" content="v2"></w-box></w-window>)
      s.find_by_id("status").not_nil!.content.should eq "v2"
    end

    it "tears down (destroys) the old layout's widgets on hot-reload" do
      # A hot-reload must `destroy` the previous layout, not merely detach it:
      # `Window#remove` leaves animation fibers (and PTYs) running, so a
      # pulsing/keyframed widget would otherwise tick forever.
      s = headless_screen
      s.load_layout %(<w-window><w-box id="fx" content="v1"></w-box></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7108)
      bridge.start

      old = s.find_by_id("fx").not_nil!
      anim = old.pulse # a never-ending ticker, stopped only by #destroy
      anim.running?.should be_true

      bridge.reload_layout %(<w-window><w-box id="fx" content="v2"></w-box></w-window>)

      # Old widget destroyed: animation stopped (no leaked fiber), new layout live.
      anim.running?.should be_false
      s.find_by_id("fx").not_nil!.content.should eq "v2"
    end

    it "returns a structured match count from mutating commands" do
      s = headless_screen
      s.load_layout %(<w-window><w-box class="x"></w-box><w-box class="x"></w-box></w-window>)
      Crysterm::HTTPBridge.new(s, port: 7103).start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7103/rpc"

      hit = HTTP::Client.post(base, body: %({"jsonrpc":"2.0","id":1,"method":"addClass","params":{"selector":".x","class":"y"}}))
      JSON.parse(hit.body)["result"].as_i.should eq 2

      miss = HTTP::Client.post(base, body: %({"jsonrpc":"2.0","id":2,"method":"addClass","params":{"selector":"#nope","class":"y"}}))
      JSON.parse(miss.body)["result"].as_i.should eq 0
    end

    it "does not append to the screen root when the parent selector matches nothing" do
      s = headless_screen
      s.load_layout %(<w-window><w-box id="root" content="r"></w-box></w-window>)
      Crysterm::HTTPBridge.new(s, port: 7106).start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7106/rpc"

      before = s.children.size

      # Selector matches no widget: nothing appended, reported count is 0.
      miss = HTTP::Client.post(base,
        body: %({"jsonrpc":"2.0","id":1,"method":"append","params":{"selector":"#nope","html":"<w-box id=\\"added\\"></w-box>"}}))
      JSON.parse(miss.body)["result"].as_i.should eq 0
      s.children.size.should eq before
      s.find_by_id("added").should be_nil

      # A matching selector still appends under that parent.
      hit = HTTP::Client.post(base,
        body: %({"jsonrpc":"2.0","id":2,"method":"append","params":{"selector":"#root","html":"<w-box id=\\"added\\"></w-box>"}}))
      JSON.parse(hit.body)["result"].as_i.should eq 1
      child = s.find_by_id("added")
      child.should_not be_nil
      s.find_by_id("root").not_nil!.children.includes?(child.not_nil!).should be_true
    end

    it "lets a handler subscribe to events at runtime (no on* attribute)" do
      s = headless_screen
      s.load_layout %(<w-window><w-button id="ok"></w-button></w-window>)
      Crysterm::HTTPBridge.new(s, port: 7104).start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7104"

      sub = HTTP::Client.post("#{base}/rpc",
        body: %({"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"selector":"#ok","event":"press"}}))
      JSON.parse(sub.body)["result"].as_i.should eq 1

      events = Channel(String).new
      spawn do
        HTTP::Client.get("#{base}/events") do |response|
          while line = response.body_io.gets
            if line.starts_with?("data: ")
              events.send line["data: ".size..]
              break
            end
          end
        end
      end
      sleep 100.milliseconds
      s.find_by_id("ok").not_nil!.emit Crysterm::Event::Pressed

      select
      when msg = events.receive
        params = JSON.parse(msg)["params"]
        params["type"].as_s.should eq "press"
        params["target"].as_s.should eq "#ok"
      when timeout(2.seconds)
        fail "no SSE event for runtime subscription"
      end
    end

    it "forwards a colon-bearing named action (unknown verb) to the handler" do
      # `navigate:home` looks declarative but names no built-in verb, so it must
      # reach the handler rather than being silently dropped.
      s = headless_screen
      s.load_layout %(<w-window><w-button id="go" onclick="navigate:home"></w-button></w-window>)
      Crysterm::HTTPBridge.new(s, port: 7105).start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7105"

      events = Channel(String).new
      spawn do
        HTTP::Client.get("#{base}/events") do |response|
          while line = response.body_io.gets
            if line.starts_with?("data: ")
              events.send line["data: ".size..]
              break
            end
          end
        end
      end
      sleep 100.milliseconds
      s.find_by_id("go").not_nil!.emit Crysterm::Event::Pressed

      select
      when msg = events.receive
        params = JSON.parse(msg)["params"]
        params["type"].as_s.should eq "press"
        params["action"].as_s.should eq "navigate:home"
        params["target"].as_s.should eq "#go"
      when timeout(2.seconds)
        fail "colon-bearing named action was not forwarded to the handler"
      end
    end

    it "removes a top-level widget from the screen (not just nested children)" do
      # A top-level widget has no widget parent, so `remove` must detach it from
      # the screen. `remove_from_parent` was a silent no-op here: reported a
      # match but left the widget on screen.
      s = headless_screen
      s.load_layout %(<w-window>) +
                    %(<w-box id="top"><w-box id="nested"></w-box></w-box>) +
                    %(</w-window>)
      Crysterm::HTTPBridge.new(s, port: 7107).start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7107/rpc"

      s.find_by_id("top").should_not be_nil
      before = s.children.size

      gone = HTTP::Client.post(base,
        body: %({"jsonrpc":"2.0","id":1,"method":"remove","params":{"selector":"#top"}}))
      JSON.parse(gone.body)["result"].as_i.should eq 1

      # Actually detached: off screen, no longer findable (nested child too).
      s.children.size.should eq before - 1
      s.find_by_id("top").should be_nil
      s.find_by_id("nested").should be_nil
    end
  end
{% end %}
