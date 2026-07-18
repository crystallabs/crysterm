require "./spec_helper"

{% if flag?(:remote) %}
  include Crysterm

  private def headless_screen
    Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
  end

  describe "Window#resolve_selector" do
    it "matches by id, class, type, and descendant combinator" do
      s = headless_screen
      s.load_layout %(<w-window>) +
                    %(<w-box id="outer" class="panel">) +
                    %(<w-button class="primary">A</w-button>) +
                    %(<w-button class="primary">B</w-button>) +
                    %(</w-box></w-window>)

      s.resolve_selector("#outer").size.should eq 1
      s.resolve_selector(".primary").size.should eq 2
      s.resolve_selector("Button").size.should eq 2
      s.resolve_selector(".panel Button").size.should eq 2
      s.resolve_selector("#nope").size.should eq 0
    end
  end

  describe "DOM::Actions (declarative)" do
    it "toggles a class on a selector with no handler" do
      s = headless_screen
      s.load_layout %(<w-window>) +
                    %(<w-box id="panel"></w-box>) +
                    %(<w-button id="b" onclick="toggle-class:#panel:open"></w-button>) +
                    %(</w-window>)
      s.wire_dom_actions

      btn = s.find_by_id("b").not_nil!
      btn.emit Crysterm::Event::Pressed
      s.find_by_id("panel").not_nil!.css_classes.includes?("open").should be_true
      btn.emit Crysterm::Event::Pressed
      s.find_by_id("panel").not_nil!.css_classes.includes?("open").should be_false
    end

    it "fires a non-button widget's onclick on a real click (and makes it hit-testable)" do
      s = headless_screen
      s.load_layout %(<w-window>) +
                    %(<w-box id="panel"></w-box>) +
                    %(<w-box id="trigger" onclick="toggle-class:#panel:open"></w-box>) +
                    %(</w-window>)
      s.wire_dom_actions

      trigger = s.find_by_id("trigger").not_nil!
      # A plain box doesn't emit Press, so the binding must go to Click — which
      # also makes the box mouse-responsive so a click can actually reach it.
      trigger.wants_mouse?.should be_true

      trigger.emit Crysterm::Event::Click
      s.find_by_id("panel").not_nil!.css_classes.includes?("open").should be_true
    end

    it "sets content via a declarative action" do
      s = headless_screen
      s.load_layout %(<w-window>) +
                    %(<w-box id="out" content="before"></w-box>) +
                    %(<w-button id="b" onclick="set-content:#out:after"></w-button>) +
                    %(</w-window>)
      s.wire_dom_actions

      s.find_by_id("b").not_nil!.emit Crysterm::Event::Pressed
      s.find_by_id("out").not_nil!.content.should eq "after"
    end

    it "routes quit through the on_quit hook" do
      s = headless_screen
      s.load_layout %(<w-window><w-button id="b" onclick="quit"></w-button></w-window>)
      quit_called = false
      s.wire_dom_actions(-> { quit_called = true; nil })

      s.find_by_id("b").not_nil!.emit Crysterm::Event::Pressed
      quit_called.should be_true
    end

    it "distinguishes declarative verbs from named actions" do
      Crysterm::DOM::Actions.declarative?("quit").should be_true
      Crysterm::DOM::Actions.declarative?("toggle-class:#x:y").should be_true
      Crysterm::DOM::Actions.declarative?("save").should be_false
    end
  end
{% end %}
