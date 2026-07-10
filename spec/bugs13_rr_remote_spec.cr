require "./spec_helper"
require "http/client"

# Regression spec for two BUGS13 findings in src/remote/:
#
#   R7 — layout-DOM load replayed attributes in initializer-arg order; the
#        ranged widgets (Slider/SpinBox/Dial/ProgressBar/...) declare `value`
#        before `minimum`/`maximum`, so a serialized `value=500 maximum=1000`
#        was clamped against the *default* range and loaded back as 100.
#        `DOM.build` now defers `value` (like `content`) until after the other
#        attributes.
#   R8 — `HTTPBridge#on_ui` posted to the window's render fiber and blocked on
#        the reply channel; with the window destroyed the render loop is gone,
#        so the posted block never ran and the HTTP fiber hung forever (every
#        subsequent embedder RPC wedging the same way). It now fails fast with
#        InvalidRequest (-32600).
#
# Guarded by -Dremote like the other bridge specs; run both ways:
#   crystal spec -Dremote spec/bugs13_rr_remote_spec.cr   # exercises the fixes
#   crystal spec          spec/bugs13_rr_remote_spec.cr   # must still compile
{% if flag?(:remote) %}
  include Crysterm

  private def headless_screen
    Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 80, height: 24, default_quit_keys: false)
  end

  describe "BUGS13 R7 — ranged value round-trips through the layout DOM" do
    it "applies a serialized value after minimum/maximum (attribute order)" do
      s = headless_screen
      begin
        # `value` serialized before `maximum` (initializer-arg order) — the
        # exact shape that used to clamp 500 against the default (0, 100).
        built = s.load_layout %(<w-window><w-slider id="sl" value="500" maximum="1000"></w-slider></w-window>)
        slider = built.first.as(Crysterm::Widget::Slider)
        slider.maximum.should eq 1000
        slider.value.should eq 500
      ensure
        s.destroy
      end
    end

    it "round-trips a ProgressBar's out-of-default-range value (serialize -> load)" do
      src = headless_screen
      dst = headless_screen
      begin
        pb = Crysterm::Widget::ProgressBar.new(parent: src, value: 500, maximum: 1000)
        html = pb.to_layout_html
        loaded = dst.load_layout(%(<w-window>#{html}</w-window>)).first.as(Crysterm::Widget::ProgressBar)
        loaded.maximum.should eq 1000
        loaded.value.should eq 500
      ensure
        src.destroy
        dst.destroy
      end
    end

    it "still lets serialized content win over a value-driven text refresh" do
      s = headless_screen
      begin
        # SpinBox rebuilds its displayed text from `value=`; the deferred
        # `value` must be applied *before* `content` so explicit serialized
        # text still wins (the pre-existing content-last invariant).
        built = s.load_layout %(<w-window><w-spinbox value="42" maximum="1000" content="custom"></w-spinbox></w-window>)
        sb = built.first.as(Crysterm::Widget::SpinBox)
        sb.value.should eq 42
        sb.content.should eq "custom"
      ensure
        s.destroy
      end
    end
  end

  describe "BUGS13 R8 — HTTPBridge fails fast instead of hanging when the window is destroyed" do
    it "answers an RPC with -32600 instead of blocking the HTTP fiber forever" do
      s = headless_screen
      s.load_layout %(<w-window><w-box id="status" content="hi"></w-box></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7461)
      bridge.start
      sleep 100.milliseconds # let the server bind
      begin
        # Destroy the window out from under the bridge (embedder shape): the
        # render loop exits, so a posted `on_ui` block would never execute.
        s.destroy

        done = Channel(JSON::Any).new(1)
        spawn do
          response = HTTP::Client.post("http://127.0.0.1:7461/rpc",
            body: %({"jsonrpc":"2.0","id":1,"method":"getContent","params":{"selector":"#status"}}))
          done.send JSON.parse(response.body)
        rescue
          # connection-level failure: leave the channel empty; the timeout fails the spec
        end

        select
        when result = done.receive
          result["error"]["code"].as_i.should eq -32_600
        when timeout(2.seconds)
          fail "RPC against a destroyed window hung (on_ui blocked forever)"
        end
      ensure
        bridge.quit rescue nil
      end
    end
  end
{% end %}
