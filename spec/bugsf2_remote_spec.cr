require "./spec_helper"
require "http/client"

# Regression specs for the BUGS-F2 Remote/DOM fixes (findings 6, 23, 52, 53, 54,
# 55). Guarded by -Dremote like the other bridge specs; run both ways:
#   crystal spec -Dremote spec/bugsf2_remote_spec.cr   # exercises the fixes
#   crystal spec          spec/bugsf2_remote_spec.cr   # must still compile
{% if flag?(:remote) %}
  include Crysterm

  private def headless_screen
    Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 80, height: 24, default_quit_keys: false)
  end

  private def rgb(name)
    Crysterm::Colors.convert(name).to_i32
  end

  # ---- Finding 6: generated dom_apply goes through real setters ------------

  describe "BUGS-F2 #6 generated dom_apply uses the public setter (side effects preserved)" do
    it "clamps a ProgressBar value set via dom_apply instead of storing it raw" do
      pb = Widget::ProgressBar.new window: headless_screen, width: 20, height: 1
      pb.maximum.should eq 100

      # Runtime setAttribute routes through dom_apply. Before the fix this wrote
      # @value directly (150, rendered >100%); now it goes through `value=`,
      # which clamps into [minimum, maximum].
      pb.dom_apply "value", "150"
      pb.value.should eq 100

      pb.dom_apply "value", "40"
      pb.value.should eq 40
    end

    it "re-clamps the value through maximum= when the range shrinks" do
      pb = Widget::ProgressBar.new window: headless_screen, width: 20, height: 1
      pb.dom_apply "value", "80"
      pb.value.should eq 80

      # `maximum=` re-clamps the current value; a raw @maximum write would leave
      # value 80 above a maximum of 50.
      pb.dom_apply "maximum", "50"
      pb.value.should eq 50
    end
  end

  # ---- Finding 23: bridge setAttribute("on*", ...) wires / re-wires --------

  describe "BUGS-F2 #23 declarative binding wiring reacts to a changed action" do
    it "replaces a changed on* action (detaches the stale binding)" do
      s = headless_screen
      btn = Widget::Button.new window: s, width: 6, height: 1
      s.append btn
      btn.dom_events["click"] = "save"

      wired = {} of String => Tuple(String, Proc(Nil))
      fired = [] of String

      DOM.each_binding(s, wired) { |_w, _type, action, _val| fired << action }
      btn.emit Crysterm::Event::Pressed
      fired.should eq ["save"]

      # Change the action and re-wire. The stale "save" binding must be detached,
      # not left firing alongside the new one.
      btn.dom_events["click"] = "delete"
      DOM.each_binding(s, wired) { |_w, _type, action, _val| fired << action }
      fired.clear
      btn.emit Crysterm::Event::Pressed
      fired.should eq ["delete"]
    end

    it "wires a brand-new binding on the next each_binding pass" do
      s = headless_screen
      btn = Widget::Button.new window: s, width: 6, height: 1
      s.append btn

      wired = {} of String => Tuple(String, Proc(Nil))
      fired = [] of String

      # No binding yet: nothing wires, nothing fires.
      DOM.each_binding(s, wired) { |_w, _type, action, _val| fired << action }
      btn.emit Crysterm::Event::Pressed
      fired.should be_empty

      # Set it (as `setAttribute("onclick", ...)` would via dom_apply), re-run:
      # now it wires and fires.
      btn.dom_apply "onclick", "go"
      DOM.each_binding(s, wired) { |_w, _type, action, _val| fired << action }
      btn.emit Crysterm::Event::Pressed
      fired.should eq ["go"]
    end

    it "wires a setAttribute(onclick) over the HTTP bridge" do
      s = headless_screen
      s.load_layout %(<w-window><w-button id="ok"></w-button></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7401)
      bridge.start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7401"
      begin
        HTTP::Client.post("#{base}/rpc",
          body: %({"jsonrpc":"2.0","id":1,"method":"setAttribute","params":{"selector":"#ok","name":"onclick","value":"save"}}))

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
        rescue
        end
        sleep 100.milliseconds

        s.find_by_id("ok").not_nil!.emit Crysterm::Event::Pressed
        select
        when msg = events.receive
          params = JSON.parse(msg)["params"]
          params["type"].as_s.should eq "press"
          params["action"].as_s.should eq "save"
          params["target"].as_s.should eq "#ok"
        when timeout(2.seconds)
          fail "setAttribute(onclick) did not wire the binding"
        end
      ensure
        bridge.quit
      end
    end
  end

  # ---- Finding 52: object-assigned stylesheet survives a layout load -------

  describe "BUGS-F2 #52 an object-assigned stylesheet survives load_layout" do
    it "keeps a CSS::Stylesheet assigned before a load_layout with no <style>" do
      s = headless_screen
      s.stylesheet = Crysterm::CSS::Stylesheet.parse("#x { color: red; }")
      s.load_layout %(<w-window><w-box id="x"></w-box></w-window>)
      s.apply_stylesheet
      # Before the fix, load_layout's add_inline_stylesheet("") recomposed from
      # only the (empty) tracked text sources and wiped the author sheet.
      s.find_by_id("x").not_nil!.styles.normal.fg.should eq rgb("red")
    end

    it "merges the object sheet with a layout's inline <style>" do
      s = headless_screen
      s.stylesheet = Crysterm::CSS::Stylesheet.parse("#x { color: red; }")
      s.load_layout %(<w-window><style>#y { color: green; }</style><w-box id="x"></w-box><w-box id="y"></w-box></w-window>)
      s.apply_stylesheet
      s.find_by_id("x").not_nil!.styles.normal.fg.should eq rgb("red")   # object rule kept
      s.find_by_id("y").not_nil!.styles.normal.fg.should eq rgb("green") # inline rule applied
    end

    it "still clears rules when everything is cleared" do
      s = headless_screen
      s.stylesheet = Crysterm::CSS::Stylesheet.parse("#x { color: red; }")
      s.stylesheet = nil # explicit object clear
      s.load_layout %(<w-window><w-box id="x"></w-box></w-window>)
      s.apply_stylesheet
      s.find_by_id("x").not_nil!.styles.normal.fg.should_not eq rgb("red")
    end
  end

  # ---- Finding 53: unsubscribe detaches by recorded uids -------------------

  describe "BUGS-F2 #53 unsubscribe stops delivery for a widget that stopped matching" do
    it "detaches the forwarder recorded at subscribe time, not the current match" do
      s = headless_screen
      s.load_layout %(<w-window><w-button id="ok" class="hot"></w-button></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7402)
      bridge.start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7402/rpc"
      begin
        HTTP::Client.post(base,
          body: %({"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"selector":".hot","event":"press"}}))
        # #ok stops matching .hot before the client unsubscribes.
        HTTP::Client.post(base,
          body: %({"jsonrpc":"2.0","id":2,"method":"removeClass","params":{"selector":"#ok","class":"hot"}}))
        HTTP::Client.post(base,
          body: %({"jsonrpc":"2.0","id":3,"method":"unsubscribe","params":{"selector":".hot","event":"press"}}))

        events = Channel(String).new(1)
        spawn do
          HTTP::Client.get("http://127.0.0.1:7402/events") do |response|
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
          fail "forwarder was not detached: still delivered #{msg}"
        when timeout(600.milliseconds)
          # Correct: no event delivered after unsubscribe.
        end
      ensure
        bridge.quit
      end
    end
  end

  # ---- Finding 54: parse-tags / wrap-content always serialized -------------

  describe "BUGS-F2 #54 base dom_attributes emits parse-tags and wrap-content explicitly" do
    it "always emits both booleans, regardless of value" do
      box = Widget::Box.new parent: headless_screen, width: 10, height: 3
      attrs = box.dom_attributes
      attrs.has_key?("parse-tags").should be_true
      attrs.has_key?("wrap-content").should be_true
    end

    it "round-trips wrap_content=true on a subclass whose default is false (Table)" do
      s = headless_screen
      t = Widget::Table.new window: s, width: 20, height: 5, wrap_content: true
      s.append t
      t.wrap_content?.should be_true

      html = t.to_layout_html
      html.should contain %(wrap-content="true")

      # Reload the serialized markup: the flipped value must survive rather than
      # reverting to Table's `false` constructor default.
      s2 = headless_screen
      s2.load_layout %(<w-window>#{html}</w-window>)
      s2.children.first.wrap_content?.should be_true
    end

    it "round-trips a default Table's wrap_content=false" do
      s = headless_screen
      t = Widget::Table.new window: s, width: 20, height: 5
      s.append t
      t.wrap_content?.should be_false

      s2 = headless_screen
      s2.load_layout %(<w-window>#{t.to_layout_html}</w-window>)
      s2.children.first.wrap_content?.should be_false
    end
  end

  # ---- Finding 55: subscribe rejects an unknown event ----------------------

  describe "BUGS-F2 #55 subscribe rejects an unknown event with BadParams" do
    it "returns a JSON-RPC -32602 and does not record the subscription" do
      s = headless_screen
      s.load_layout %(<w-window><w-button id="ok"></w-button></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7403)
      bridge.start
      sleep 100.milliseconds
      base = "http://127.0.0.1:7403/rpc"
      begin
        resp = HTTP::Client.post(base,
          body: %({"jsonrpc":"2.0","id":1,"method":"subscribe","params":{"selector":"#ok","event":"clik"}}))
        body = JSON.parse(resp.body)
        body["error"]["code"].should eq -32_602
        body["error"]["message"].as_s.should contain "clik"

        # A valid event still works (proves the guard only rejects unknowns).
        ok = HTTP::Client.post(base,
          body: %({"jsonrpc":"2.0","id":2,"method":"subscribe","params":{"selector":"#ok","event":"press"}}))
        JSON.parse(ok.body)["result"].as_i.should eq 1
      ensure
        bridge.quit
      end
    end
  end
{% end %}
