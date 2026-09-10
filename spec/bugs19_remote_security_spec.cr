require "./spec_helper"
require "http/client"

# Security regressions for the layout DOM and the HTTP bridge. Guarded by
# -Dremote like the other bridge specs; run both ways:
#   crystal spec -Dremote spec/bugs19_remote_security_spec.cr  # exercises them
#   crystal spec          spec/bugs19_remote_security_spec.cr  # must compile
{% if flag?(:remote) %}
  include Crysterm

  # Polls the bridge's port instead of sleeping a fixed margin: `#start` binds
  # (and listens) synchronously, so the very first probe normally succeeds, and
  # a bridge that never came up fails loudly instead of passing late.
  private def wait_for_bind(port : Int32)
    wait_until do
      TCPSocket.new("127.0.0.1", port).close
      true
    rescue
      false
    end
  end

  # ---- markup can never start a process --------------------------------------

  describe "Widget::Terminal is not loadable from markup" do
    it "is absent from the DOM registry" do
      Crysterm::DOM.registry.has_key?("terminal").should be_false
    end

    it "builds nothing for a <w-terminal> element, at top level or nested" do
      s = headless_screen(80, 24)
      s.load_layout %(<w-window>) +
                    %(<w-terminal id="top" shell="/nonexistent/pwned"></w-terminal>) +
                    %(<w-box id="host"><w-terminal id="nested" shell="/nonexistent/pwned"></w-terminal></w-box>) +
                    %(</w-window>)

      s.find_by_id("top").nil?.should be_true
      s.find_by_id("nested").nil?.should be_true
      # The rest of the layout still loads: an unregistered tag is skipped, not
      # fatal.
      host = s.find_by_id("host")
      host.nil?.should be_false
      host.not_nil!.children.any? { |c| c.is_a?(Widget::Terminal) }.should be_false
      s.children.any? { |c| c.is_a?(Widget::Terminal) }.should be_false
    end

    it "neither emits nor replays process-launch attributes" do
      s = headless_screen(80, 24)
      # `handler:` drives the widget from the outside, so no PTY is ever
      # spawned by this spec.
      term = Widget::Terminal.new window: s, handler: ->(_data : String) { },
        shell: "/nonexistent/spawned", term_name: "xterm-spec"

      attrs = term.dom_attributes
      attrs.has_key?("shell").should be_false
      attrs.has_key?("args").should be_false
      attrs.has_key?("env").should be_false
      attrs.has_key?("term-name").should be_false

      # And the names are unknown on the apply side too, so a `setAttribute`
      # RPC or a hand-written attribute can't reach them either.
      term.dom_apply("shell", "/nonexistent/pwned").should be_false
      term.dom_apply("args", "-c;evil").should be_false
      term.dom_apply("env", "LD_PRELOAD=/x").should be_false
      term.dom_apply("term-name", "xterm-pwned").should be_false

      html = term.to_layout_html
      html.should_not contain "/nonexistent/spawned"
      html.should_not contain "shell="
      html.should_not contain "term-name="
    end
  end

  # ---- the bridge is not reachable from a web page ---------------------------

  describe "HTTPBridge refuses browser-originated requests" do
    it "rejects an Origin / cross-site POST and applies nothing" do
      s = headless_screen(default_quit_keys: true)
      s.load_layout %(<w-window><w-box id="status" content="hi"></w-box></w-window>)

      Crysterm::HTTPBridge.new(s, port: 7490).start
      wait_for_bind 7490
      url = "http://127.0.0.1:7490/rpc"
      body = %({"jsonrpc":"2.0","method":"setContent","params":{"selector":"#status","value":"pwned"}})

      HTTP::Client.post(url, headers: HTTP::Headers{"Origin" => "https://evil.example"},
        body: body).status_code.should eq 403
      HTTP::Client.post(url, headers: HTTP::Headers{"Sec-Fetch-Site" => "cross-site"},
        body: body).status_code.should eq 403
      HTTP::Client.post(url, headers: HTTP::Headers{"Sec-Fetch-Site" => "same-site"},
        body: body).status_code.should eq 403

      # None of the three reached the tree.
      s.find_by_id("status").not_nil!.content.should eq "hi"

      # A direct (non-browser) client is unaffected, with or without the
      # navigation-only `Sec-Fetch-Site: none`.
      HTTP::Client.post(url, headers: HTTP::Headers{"Sec-Fetch-Site" => "none"},
        body: body).status_code.should eq 200
      wait_until { s.find_by_id("status").not_nil!.content == "pwned" }
    end

    it "rejects an Origin on the event stream too" do
      s = headless_screen(default_quit_keys: true)
      Crysterm::HTTPBridge.new(s, port: 7491).start
      wait_for_bind 7491

      # A read timeout, so an accepted (and therefore endless) SSE stream fails
      # the spec instead of hanging it.
      client = HTTP::Client.new "127.0.0.1", 7491
      client.read_timeout = 2.seconds
      begin
        client.get("/events", headers: HTTP::Headers{"Origin" => "https://evil.example"}).status_code.should eq 403
      ensure
        client.close
      end
    end
  end

  describe "HTTPBridge refuses a POST whose body is not typed as JSON" do
    it "answers 415 for the form/simple-request content types" do
      s = headless_screen(default_quit_keys: true)
      s.load_layout %(<w-window><w-box id="status" content="hi"></w-box></w-window>)

      Crysterm::HTTPBridge.new(s, port: 7492).start
      wait_for_bind 7492
      url = "http://127.0.0.1:7492/rpc"
      body = %({"jsonrpc":"2.0","method":"setContent","params":{"selector":"#status","value":"pwned"}})

      %w[text/plain;charset=UTF-8 application/x-www-form-urlencoded multipart/form-data].each do |ct|
        HTTP::Client.post(url, headers: HTTP::Headers{"Content-Type" => ct},
          body: body).status_code.should eq 415
      end
      s.find_by_id("status").not_nil!.content.should eq "hi"

      # JSON is accepted, including a charset parameter and odd casing.
      HTTP::Client.post(url, headers: HTTP::Headers{"Content-Type" => "Application/JSON; charset=utf-8"},
        body: body).status_code.should eq 200
      wait_until { s.find_by_id("status").not_nil!.content == "pwned" }
    end
  end
{% end %}
