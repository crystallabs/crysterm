require "./spec_helper"
require "http/client"

# Regression specs for BUGS6.md section 9 (Remote / DOM Remoting Layer).
# Guarded by -Dremote like the other bridge specs; run with:
#   crystal spec -Dremote spec/bugs6_remote_spec.cr
{% if flag?(:remote) %}
  include Crysterm

  private def headless_screen
    Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
  end

  private def rgb(name)
    Crysterm::Colors.convert(name).to_i32
  end

  # Exposes the private, render-fiber-marshaling `#on_ui` so a spec can drive a
  # UI job that raises and observe the requesting fiber's behavior directly
  # (raising an exception through the full HTTP stack on demand is awkward).
  private class ProbeBridge < Crysterm::HTTPBridge
    def pub_on_ui(&block : -> T) : T forall T
      on_ui(&block)
    end
  end

  describe "BUGS6 section 9 — remote bridge" do
    # Bug 1 (Medium/High): an exception in a bridge UI job must not hang the
    # requesting fiber and must not kill the render fiber.
    describe "UI-job exception handling" do
      it "re-raises a raising on_ui job on the requesting fiber (no hang)" do
        s = headless_screen
        bridge = ProbeBridge.new(s, port: 7200)

        # Before the fix this would block forever on `result.receive` (the job
        # raised on the render fiber and never sent) — hanging the request.
        expect_raises(Exception, "boom") do
          bridge.pub_on_ui { raise "boom" }
        end
      end

      it "keeps the render fiber alive after an on_ui job raises" do
        s = headless_screen
        bridge = ProbeBridge.new(s, port: 7201)

        bridge.pub_on_ui { raise "boom" } rescue nil
        # A dead render fiber would never run this second job → would hang.
        bridge.pub_on_ui { 42 }.should eq 42
      end

      it "does not let a raising posted job kill the render fiber (drain_ui_queue)" do
        s = headless_screen
        done = Channel(Nil).new
        s.post { raise "boom in a bare posted job" }
        s.post { done.send nil }

        select
        when done.receive
          # render fiber survived the raising job and drained the next one
        when timeout(2.seconds)
          fail "render fiber died on a raising posted job (job queue stalled)"
        end
      end
    end

    # Bug 2 (Low/Medium): stale inline <style> CSS must not survive a hot-reload
    # to a layout that carries no <style>.
    it "clears stale inline <style> CSS on a hot-reload to a style-less layout" do
      # Baseline: the default fg for #x with no matching rule.
      control = headless_screen
      control.load_layout %(<w-window><w-box id="x"></w-box></w-window>)
      control.apply_stylesheet
      default_fg = control.find_by_id("x").not_nil!.styles.normal.fg

      s = headless_screen
      s.load_layout %(<w-window><style>#x{color:red}</style><w-box id="x"></w-box></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7202)
      bridge.start
      s.apply_stylesheet
      s.find_by_id("x").not_nil!.styles.normal.fg.should eq rgb("red")

      # Reload to a layout with NO <style>: the previous inline rule must go.
      bridge.reload_layout %(<w-window><w-box id="x"></w-box></w-window>)
      s.apply_stylesheet
      s.find_by_id("x").not_nil!.styles.normal.fg.should eq default_fg
    end

    # Bug 3 (Low): malformed / non-object JSON-RPC bodies must map to structured
    # JSON-RPC errors, not an uncaught 500 / broken socket.
    describe "malformed JSON-RPC bodies" do
      it "returns -32700 for unparseable JSON and -32600 for non-object JSON" do
        s = headless_screen
        s.load_layout %(<w-window><w-box id="x"></w-box></w-window>)
        Crysterm::HTTPBridge.new(s, port: 7203).start
        sleep 100.milliseconds
        base = "http://127.0.0.1:7203/rpc"

        bad_json = HTTP::Client.post(base, body: "{ this is not json")
        bad_json.status_code.should eq 200
        JSON.parse(bad_json.body)["error"]["code"].as_i.should eq -32_700

        {"5", %("x"), "[]"}.each do |non_object|
          resp = HTTP::Client.post(base, body: non_object)
          resp.status_code.should eq 200
          JSON.parse(resp.body)["error"]["code"].as_i.should eq -32_600
        end
      end
    end

    # Bug 4 (Low): setAttribute("class", …) must REPLACE the class list (browser
    # semantics), not accumulate.
    it "replaces the class list on setAttribute(\"class\", …)" do
      s = headless_screen
      s.load_layout %(<w-window><w-box id="x" class="a b"></w-box></w-window>)
      Crysterm::HTTPBridge.new(s, port: 7204).start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7204/rpc"

      HTTP::Client.post(base,
        body: %({"jsonrpc":"2.0","method":"setAttribute","params":{"selector":"#x","name":"class","value":"c"}}))

      s.find_by_id("x").not_nil!.css_classes.to_a.sort.should eq ["c"]
    end

    # Bug 5 (Low): subscribing to an unknown event wires nothing, so it must
    # report 0 rather than the match count.
    it "reports 0 subscriptions for an unknown event name" do
      s = headless_screen
      s.load_layout %(<w-window><w-button id="ok"></w-button></w-window>)
      Crysterm::HTTPBridge.new(s, port: 7205).start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7205/rpc"

      unknown = HTTP::Client.post(base,
        body: %({"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"selector":"#ok","event":"bogus"}}))
      JSON.parse(unknown.body)["result"].as_i.should eq 0

      # Sanity: a known event still wires and reports its match count.
      known = HTTP::Client.post(base,
        body: %({"jsonrpc":"2.0","id":2,"method":"subscribe","params":{"selector":"#ok","event":"press"}}))
      JSON.parse(known.body)["result"].as_i.should eq 1
    end

    # Bug 6 (Low/hardening): token accepted only via the X-Crysterm-Token header,
    # never a query param.
    describe "token hardening" do
      it "accepts the header token but rejects a query-param token" do
        s = headless_screen
        s.load_layout %(<w-window><w-box id="x"></w-box></w-window>)
        Crysterm::HTTPBridge.new(s, port: 7206, token: "s3cret").start
        sleep 100.milliseconds
        body = %({"jsonrpc":"2.0","method":"render"})

        # Correct header: authorized.
        HTTP::Client.post("http://127.0.0.1:7206/rpc",
          headers: HTTP::Headers{"X-Crysterm-Token" => "s3cret"}, body: body).status_code.should eq 200

        # Query-param token (leaks into logs) is no longer honored.
        HTTP::Client.post("http://127.0.0.1:7206/rpc?token=s3cret", body: body).status_code.should eq 401

        # Wrong / missing header: rejected.
        HTTP::Client.post("http://127.0.0.1:7206/rpc", body: body).status_code.should eq 401
        HTTP::Client.post("http://127.0.0.1:7206/rpc",
          headers: HTTP::Headers{"X-Crysterm-Token" => "nope"}, body: body).status_code.should eq 401
      end
    end
  end
{% end %}
