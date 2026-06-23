require "./spec_helper"

{% if flag?(:remote) %}
  include Crysterm

  # Exercises the *layout DOM*: the round-trippable, loadable HTML emitted by
  # `#to_layout_html` and rebuilt by `DOM.load`. Where `css_spec.cr` pins the
  # minimal match-only document, these tests pin that construction state survives
  # a serialize -> load -> serialize round-trip.

  private def headless_screen
    Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
  end

  describe "Layout DOM (#to_layout_html / DOM.load)" do
    it "serializes construction state as attributes (not computed values)" do
      s = headless_screen
      box = Widget::Box.new parent: s, top: "center", left: 2, width: "50%", height: 5,
        content: "Hi", parse_tags: true
      box.css_id = "main"

      html = box.to_layout_html
      html.should contain %(<w-box)
      html.should contain %(id="main")
      html.should contain %(top="center")
      html.should contain %(left="2")
      html.should contain %(width="50%")
      html.should contain %(height="5")
      html.should contain %(content="Hi")
      html.should contain %(parse-tags="true")
      # No computed geometry leaks in.
      html.should_not contain "aleft"
    end

    it "rebuilds a widget tree from layout HTML" do
      s = headless_screen
      html = <<-HTML
      <w-screen>
        <w-box id="outer" top="1" left="2" width="40" height="10">
          <w-button id="ok" top="center" left="center" width="10" height="3" content="OK"></w-button>
        </w-box>
      </w-screen>
      HTML

      built = s.load_layout(html)
      built.size.should eq 1

      outer = s.find_by_id("outer").not_nil!
      outer.should be_a Widget::Box
      outer.top.should eq 1
      outer.left.should eq 2
      outer.width.should eq 40
      outer.children.size.should eq 1

      ok = s.find_by_id("ok").not_nil!
      ok.should be_a Widget::Button
      ok.top.should eq "center"
      ok.content.should eq "OK"
      ok.parent.should eq outer
    end

    it "round-trips a tree losslessly" do
      s1 = headless_screen
      outer = Widget::Box.new parent: s1, top: 1, left: 2, width: 40, height: 10
      outer.css_id = "outer"
      Widget::Button.new parent: outer, top: "center", left: "center",
        width: 10, height: 3, content: "OK", checkable: true, checked: true

      first = s1.to_layout_html

      s2 = headless_screen
      s2.load_layout(first)
      second = s2.to_layout_html

      second.should eq first
    end

    it "restores list items" do
      s = headless_screen
      list = Widget::List.new parent: s, items: ["a", "b", "c"]
      html = list.to_layout_html
      html.should contain %(items="a\nb\nc")

      s2 = headless_screen
      s2.load_layout(list.to_layout_html)
      s2.find_by_id(list.css_id || "").try(&.as(Widget::List))
      rebuilt = s2.children.first.as(Widget::List)
      rebuilt.ritems.should eq ["a", "b", "c"]
    end

    it "skips unknown tags instead of failing" do
      s = headless_screen
      built = s.load_layout %(<w-screen><w-nonesuch></w-nonesuch><w-box></w-box></w-screen>)
      built.size.should eq 1
      built.first.should be_a Widget::Box
    end
  end
{% end %}
