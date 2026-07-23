require "./spec_helper"

# Regression specs for the BUGS18 Remote/DOM fixes (findings B18-106, B18-108).
# Guarded by -Dremote like the other bridge/dom specs; run both ways:
#   crystal spec -Dremote spec/bugs18_remote_dom_spec.cr   # exercises the fixes
#   crystal spec          spec/bugs18_remote_dom_spec.cr   # must still compile
{% if flag?(:remote) %}
  include Crysterm

  private def headless_screen
    Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 80, height: 24, default_quit_keys: false)
  end

  # ---- B18-106: set-content's selector split respects pseudo-classes -------

  describe "BUGS18 #106 DOM::Actions set-content splits selector/text at the compile boundary" do
    it "keeps a :nth-child(...) pseudo-class as part of the selector, not the text" do
      s = headless_screen
      s.load_layout %(<w-window>) +
                    %(<w-box class="item">one</w-box>) +
                    %(<w-box class="item">two</w-box>) +
                    %(<w-button id="b" onclick="set-content:.item:nth-child(2):Done"></w-button>) +
                    %(</w-window>)
      s.wire_dom_actions

      items = s.resolve_selector(".item")
      items.size.should eq 2
      first, second = items

      s.find_by_id("b").not_nil!.emit Crysterm::Event::Pressed

      # Before the fix, a left `partition(':')` split at the FIRST colon: sel
      # became ".item" and text became "nth-child(2):Done", so *every* .item
      # widget's content was clobbered with that literal string.
      second.content.should eq "Done"
      first.content.should eq "one"
    end

    it "keeps a colon inside the free-text argument, splitting on the selector's own boundary" do
      s = headless_screen
      s.load_layout %(<w-window>) +
                    %(<w-box id="msg" content="before"></w-box>) +
                    %(<w-button id="b" onclick="set-content:#msg:Warning: disk full"></w-button>) +
                    %(</w-window>)
      s.wire_dom_actions

      s.find_by_id("b").not_nil!.emit Crysterm::Event::Pressed

      # "#msg:Warning" doesn't compile (unknown pseudo-class "Warning"), so the
      # boundary falls right after "#msg" and the rest — including its colon —
      # is the text.
      s.find_by_id("msg").not_nil!.content.should eq "Warning: disk full"
    end

    it "still handles a colon-free selector and the bare/@self forms unchanged" do
      s = headless_screen
      s.load_layout %(<w-window>) +
                    %(<w-box id="out" content="before"></w-box>) +
                    %(<w-button id="b" onclick="set-content:#out:after"></w-button>) +
                    %(<w-button id="c" onclick="set-content::self-text"></w-button>) +
                    %(</w-window>)
      s.wire_dom_actions

      s.find_by_id("b").not_nil!.emit Crysterm::Event::Pressed
      s.find_by_id("out").not_nil!.content.should eq "after"

      # Empty selector segment targets the firing widget itself (`@self`
      # equivalent); must still resolve to the source widget, not crash on an
      # empty compile probe.
      s.find_by_id("c").not_nil!.emit Crysterm::Event::Pressed
      s.find_by_id("c").not_nil!.content.should eq "self-text"
    end
  end

  # ---- B18-108: wire_dom_actions is idempotent across repeated calls -------

  describe "BUGS18 #108 Window#wire_dom_actions dedups across repeated calls" do
    it "does not double-wire an existing binding on a second call (toggle-class stays a single toggle)" do
      s = headless_screen
      s.load_layout %(<w-window>) +
                    %(<w-box id="panel"></w-box>) +
                    %(<w-button id="b" onclick="toggle-class:#panel:open"></w-button>) +
                    %(</w-window>)
      s.wire_dom_actions
      # Simulates the natural repeat-call flow: re-wiring after loading more of
      # the tree (e.g. a fragment appended via DOM.load).
      s.wire_dom_actions

      btn = s.find_by_id("b").not_nil!
      panel = s.find_by_id("panel").not_nil!

      # Before the fix, each_binding was called with no `wired` map, so the
      # second call installed a second handler for the same binding: one press
      # would toggle "open" on then immediately back off (net no-op).
      btn.emit Crysterm::Event::Pressed
      panel.css_classes.includes?("open").should be_true

      btn.emit Crysterm::Event::Pressed
      panel.css_classes.includes?("open").should be_false
    end

    it "wires a binding added by a later DOM.load append without re-wiring the old ones" do
      s = headless_screen
      s.load_layout %(<w-window>) +
                    %(<w-box id="panel"></w-box>) +
                    %(<w-button id="b" onclick="toggle-class:#panel:open"></w-button>) +
                    %(</w-window>)
      s.wire_dom_actions

      DOM.load %(<w-button id="b2" onclick="toggle-class:#panel:closed"></w-button>), s
      s.wire_dom_actions

      panel = s.find_by_id("panel").not_nil!

      s.find_by_id("b").not_nil!.emit Crysterm::Event::Pressed
      panel.css_classes.includes?("open").should be_true

      s.find_by_id("b2").not_nil!.emit Crysterm::Event::Pressed
      panel.css_classes.includes?("closed").should be_true

      # The original binding must still fire exactly once per press, not
      # twice, after the second wire_dom_actions call that picked up b2.
      s.find_by_id("b").not_nil!.emit Crysterm::Event::Pressed
      panel.css_classes.includes?("open").should be_false
    end

    it "updates on_quit for already-wired bindings on a later call" do
      s = headless_screen
      s.load_layout %(<w-window><w-button id="b" onclick="quit"></w-button></w-window>)

      first_called = false
      second_called = false
      s.wire_dom_actions(-> { first_called = true; nil })
      s.wire_dom_actions(-> { second_called = true; nil })

      s.find_by_id("b").not_nil!.emit Crysterm::Event::Pressed

      # Without persisting the latest on_quit and re-reading it at fire time,
      # the "quit" binding (unchanged action, so left alone by each_binding's
      # dedup) would still invoke the *first* call's captured proc.
      second_called.should be_true
      first_called.should be_false
    end
  end
{% end %}
