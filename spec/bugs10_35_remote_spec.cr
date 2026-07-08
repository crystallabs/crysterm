require "./spec_helper"
require "http/client"

# Regression spec for BUGS10 #35: `unsubscribe` detached event forwarders still
# owned by other live subscriptions. Forwarders are deduped per widget+event, so
# two subscriptions whose selectors match the same widget share one forwarder;
# tearing down by one subscription's recorded keys alone silently stopped
# delivery for the survivor. Guarded by -Dremote like the other bridge specs;
# run both ways:
#   crystal spec -Dremote spec/bugs10_35_remote_spec.cr   # exercises the fix
#   crystal spec          spec/bugs10_35_remote_spec.cr   # must still compile
{% if flag?(:remote) %}
  include Crysterm

  private def headless_screen
    Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 80, height: 24, default_quit_keys: false)
  end

  # Waits for one `data:` payload from the SSE stream, or nil on timeout.
  private def next_event(port, wait, &) : String?
    events = Channel(String).new(1)
    spawn do
      HTTP::Client.get("http://127.0.0.1:#{port}/events") do |response|
        while line = response.body_io.gets
          if line.starts_with?("data: ")
            events.send line["data: ".size..]
            break
          end
        end
      end
    rescue
    end
    sleep 100.milliseconds
    yield
    select
    when msg = events.receive
      msg
    when timeout(wait)
      nil
    end
  end

  describe "BUGS10 #35 unsubscribe keeps forwarders shared with live subscriptions" do
    it "still delivers to the surviving subscription after the overlapping one unsubscribes" do
      s = headless_screen
      s.load_layout %(<w-window><w-button id="save" class="btn"></w-button></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7404)
      bridge.start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7404/rpc"
      begin
        # Both selectors match the same widget: one shared forwarder, two
        # subscriptions each recording the same "uid:press" key.
        HTTP::Client.post(base,
          body: %({"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"selector":"#save","event":"press"}}))
        HTTP::Client.post(base,
          body: %({"jsonrpc":"2.0","id":2,"method":"subscribe","params":{"selector":".btn","event":"press"}}))
        HTTP::Client.post(base,
          body: %({"jsonrpc":"2.0","id":3,"method":"unsubscribe","params":{"selector":"#save","event":"press"}}))

        msg = next_event(7404, 600.milliseconds) do
          s.find_by_id("save").not_nil!.emit Crysterm::Event::Press
        end
        msg.should_not be_nil # the .btn subscription is still live
      ensure
        bridge.quit
      end
    end

    it "detaches the forwarder once the last referencing subscription unsubscribes" do
      s = headless_screen
      s.load_layout %(<w-window><w-button id="save" class="btn"></w-button></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7405)
      bridge.start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7405/rpc"
      begin
        HTTP::Client.post(base,
          body: %({"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"selector":"#save","event":"press"}}))
        HTTP::Client.post(base,
          body: %({"jsonrpc":"2.0","id":2,"method":"subscribe","params":{"selector":".btn","event":"press"}}))
        HTTP::Client.post(base,
          body: %({"jsonrpc":"2.0","id":3,"method":"unsubscribe","params":{"selector":"#save","event":"press"}}))
        HTTP::Client.post(base,
          body: %({"jsonrpc":"2.0","id":4,"method":"unsubscribe","params":{"selector":".btn","event":"press"}}))

        msg = next_event(7405, 600.milliseconds) do
          s.find_by_id("save").not_nil!.emit Crysterm::Event::Press
        end
        msg.should be_nil # no subscription left; forwarder must be detached
      ensure
        bridge.quit
      end
    end
  end
{% end %}
