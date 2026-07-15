require "./spec_helper"

# Regression specs for the BUGS8 Remote/DOM fixes. Guarded by -Dremote like the
# other bridge specs; run with:
#   crystal spec -Dremote spec/bugs8_remote_spec.cr
{% if flag?(:remote) %}
  include Crysterm

  private def headless_screen
    Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
  end

  describe "BUGS8 item views don't double their rows on a layout-DOM round-trip" do
    it "serializes a List's rows only as items= (no phantom <w-box> children)" do
      s = headless_screen
      list = Widget::List.new parent: s, width: 10, height: 5
      list.css_id = "l"
      %w[a b c].each { |i| list.add_item i }
      list.children.size.should eq 3 # the backing item boxes

      html = list.to_layout_html
      html.should contain %(items="a\nb\nc")
      # The rows must NOT also appear as nested child nodes.
      html.should_not contain "<w-box"
    end

    it "rebuilds a 3-item List to 3 children (not 6) across a round-trip" do
      s = headless_screen
      html = %(<w-window><w-list id="l" width="10" height="5" items="a&#10;b&#10;c"></w-list></w-window>)
      s.load_layout html

      list = s.find_by_id("l").not_nil!.as(Widget::List)
      list.ritems.should eq %w[a b c]
      list.children.size.should eq 3 # rebuilt from items=, no re-appended phantoms
    end

    it "is stable across a second serialize→load cycle" do
      s = headless_screen
      list = Widget::List.new parent: s, width: 10, height: 5
      list.css_id = "l"
      %w[x y].each { |i| list.add_item i }

      once = s.to_layout_html
      s2 = headless_screen
      s2.load_layout once
      twice = s2.to_layout_html
      # Idempotent: the same document comes back out.
      twice.should eq once

      relisted = s2.find_by_id("l").not_nil!.as(Widget::List)
      relisted.ritems.should eq %w[x y]
      relisted.children.size.should eq 2
    end

    it "ignores stale serialized <w-box> children under an item view (defensive)" do
      # A layout written before the save-side skip would carry phantom item
      # boxes; the loader must not re-append them.
      s = headless_screen
      html = %(<w-window><w-list id="l" width="10" height="5" items="a&#10;b">) +
             %(<w-box content="a"></w-box><w-box content="b"></w-box></w-list></w-window>)
      s.load_layout html
      list = s.find_by_id("l").not_nil!.as(Widget::List)
      list.ritems.should eq %w[a b]
      list.children.size.should eq 2
    end
  end

  describe "BUGS8 List#dom_apply(\"items\") replaces rather than appends" do
    it "replaces the row set on a repeated apply (setAttribute semantics)" do
      s = headless_screen
      list = Widget::List.new parent: s, width: 10, height: 5
      list.dom_apply "items", "a\nb\nc"
      list.ritems.should eq %w[a b c]

      # A browser's setAttribute replaces; without the clear this would grow to
      # a\nb\nc\nx\ny (the accumulation bug fixed for `class` earlier).
      list.dom_apply "items", "x\ny"
      list.ritems.should eq %w[x y]
      list.children.size.should eq 2
    end
  end

  describe "BUGS8 on_widget_event returns a working detacher (unsubscribe)" do
    it "stops delivery once the detacher is called" do
      s = headless_screen
      btn = Widget::Button.new parent: s, width: 6, height: 3, content: "OK"

      seen = [] of String
      detach = Crysterm::DOM.on_widget_event(btn, "press") { |type, _| seen << type }
      detach.should_not be_nil

      btn.emit Crysterm::Event::Press
      seen.size.should eq 1

      detach.not_nil!.call
      btn.emit Crysterm::Event::Press
      seen.size.should eq 1 # no longer delivered — the handler was removed via #off
    end

    it "returns nil for an unknown event name (nothing wired)" do
      s = headless_screen
      btn = Widget::Button.new parent: s, width: 6, height: 3
      Crysterm::DOM.on_widget_event(btn, "nonsense") { |_, _| }.should be_nil
    end
  end
{% end %}
