require "./spec_helper"
require "http/client"

# Regression specs for the BUGS17 Remote/DOM fixes (findings B17-39, B17-40,
# B17-41, B17-43). Guarded by -Dremote like the other bridge specs; run both
# ways:
#   crystal spec -Dremote spec/bugs17_remote_spec.cr   # exercises the fixes
#   crystal spec          spec/bugs17_remote_spec.cr   # must still compile
{% if flag?(:remote) %}
  include Crysterm

  private def headless_screen
    Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 80, height: 24, default_quit_keys: false)
  end

  private def rgb(name)
    Crysterm::Colors.convert(name).to_i32
  end

  # ---- B17-39: string-valued right/bottom anchors survive the round-trip ----

  describe "BUGS17 #39 dom_apply coerces string right/bottom anchors" do
    it "round-trips right: \"50%\" / bottom: \"center\" through to_layout_html -> load_layout" do
      s = headless_screen
      box = Widget::Box.new parent: s, right: "50%", bottom: "center", width: 10, height: 3
      box.css_id = "anchored"

      html = s.to_layout_html
      html.should contain %(right="50%")
      html.should contain %(bottom="center")

      # Before the fix, `"50%".to_i?` was nil so the assignment was skipped and
      # the anchor silently dropped on load.
      s2 = headless_screen
      s2.load_layout html
      loaded = s2.find_by_id("anchored").not_nil!
      loaded.right.should eq "50%"
      loaded.bottom.should eq "center"

      # And the pair is a fixed point: the second serialization still carries the
      # anchors.
      s2.to_layout_html.should eq html
    end

    it "still coerces a bare-integer right/bottom to Int32" do
      s = headless_screen
      box = Widget::Box.new parent: s, width: 4, height: 1
      box.dom_apply "right", "2"
      box.dom_apply "bottom", "3"
      box.right.should eq 2
      box.bottom.should eq 3
    end
  end

  # ---- B17-40: the remove RPC destroys (stops fibers/PTYs), not just detaches -

  describe "BUGS17 #40 remove RPC destroys the widget" do
    it "destroys removed widgets (stops animations + fires Event::Destroy)" do
      s = headless_screen
      s.load_layout %(<w-window><w-box id="panel" content="v"></w-box></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7470)
      bridge.start
      sleep 100.milliseconds
      begin
        panel = s.find_by_id("panel").not_nil!
        anim = panel.pulse # a never-ending ticker, stopped only by #destroy
        anim.running?.should be_true
        destroyed = false
        panel.on(Crysterm::Event::Destroy) { destroyed = true }

        HTTP::Client.post("http://127.0.0.1:7470/rpc",
          body: %({"jsonrpc":"2.0","id":1,"method":"remove","params":{"selector":"#panel"}}))
        sleep 100.milliseconds

        # Before the fix, `remove` only detached: the animation fiber kept ticking
        # forever and Event::Destroy never fired.
        destroyed.should be_true
        anim.running?.should be_false
        s.find_by_id("panel").should be_nil
      ensure
        bridge.quit
      end
    end
  end

  # ---- B17-41: an on* binding can be removed (nil setAttribute) --------------

  describe "BUGS17 #41 removing an on* binding stops it firing" do
    it "deletes the dom_events entry on a nil (and empty) value" do
      box = Widget::Box.new parent: headless_screen, width: 4, height: 1
      box.dom_apply "onclick", "save"
      box.dom_events["click"]?.should eq "save"

      # nil value (the bridge's setAttribute-with-no-value removal shape) deletes
      # the binding instead of storing "".
      box.dom_apply "onclick", nil
      box.dom_events.has_key?("click").should be_false

      # An empty string (bare `onclick` HTML attribute) is likewise a removal.
      box.dom_apply "onclick", "keep"
      box.dom_apply "onclick", ""
      box.dom_events.has_key?("click").should be_false
    end

    it "prunes a removed binding on the next each_binding pass (no empty-action event)" do
      s = headless_screen
      btn = Widget::Button.new window: s, width: 6, height: 1
      s.append btn
      btn.dom_events["click"] = "save"

      wired = {} of String => Tuple(String, Proc(Nil))
      fired = [] of String

      DOM.each_binding(s, wired) { |_w, _t, action, _v| fired << action }
      btn.emit Crysterm::Event::Pressed
      fired.should eq ["save"]

      # Remove the binding (as `setAttribute("onclick")` with no value would), then
      # re-wire. The stale "save" subscription must be detached: a later click
      # publishes nothing — no bogus empty-action event.
      btn.dom_apply "onclick", nil
      DOM.each_binding(s, wired) { |_w, _t, action, _v| fired << action }
      fired.clear
      btn.emit Crysterm::Event::Pressed
      fired.should be_empty
      wired.should be_empty # the wired entry was pruned, not left dangling
    end

    it "removes the binding over the HTTP bridge (no further events published)" do
      s = headless_screen
      s.load_layout %(<w-window><w-button id="ok" onclick="save"></w-button></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7471)
      bridge.start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7471"
      begin
        # Remove the onclick binding: setAttribute with no `value` param.
        HTTP::Client.post("#{base}/rpc",
          body: %({"jsonrpc":"2.0","id":1,"method":"setAttribute","params":{"selector":"#ok","name":"onclick"}}))

        events = Channel(String).new(1)
        spawn do
          HTTP::Client.get("#{base}/events") do |response|
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

        s.find_by_id("ok").not_nil!.emit Crysterm::Event::Pressed
        select
        when msg = events.receive
          fail "binding was not removed: still published #{msg}"
        when timeout(600.milliseconds)
          # Correct: no event published after the onclick binding was removed.
        end
      ensure
        bridge.quit
      end
    end
  end

  # ---- B17-43: snapshot preserves the inline <style> ------------------------

  describe "BUGS17 #43 to_layout_html serializes the inline <style>" do
    it "includes the inline stylesheet and is a snapshot -> load -> snapshot fixed point" do
      s = headless_screen
      s.load_layout %(<w-window><style>#hdr { color: red }</style><w-box id="hdr"></w-box></w-window>)

      snap1 = s.to_layout_html
      snap1.should contain "<style>"
      snap1.should contain "#hdr { color: red }"

      # Loading the snapshot and re-snapshotting is a fixed point for the styles:
      # the trailing newline collect_style_css adds on load is normalized away.
      s2 = headless_screen
      s2.load_layout snap1
      snap2 = s2.to_layout_html
      snap2.should contain "<style>"
      snap2.should eq snap1

      # The reloaded window actually applies the preserved inline rule.
      s2.apply_stylesheet
      s2.find_by_id("hdr").not_nil!.styles.normal.fg.should eq rgb("red")
    end

    it "emits no <style> when the layout has no inline CSS" do
      s = headless_screen
      s.load_layout %(<w-window><w-box id="x"></w-box></w-window>)
      s.to_layout_html.should_not contain "<style>"
    end
  end
{% end %}
