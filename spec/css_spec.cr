require "./spec_helper"
require "html5"

include Crysterm

# Locks the CSS document the styling subsystem hands to the `html5` selector
# engine. These tests pin (a) the per-widget identity emitted by `#to_html` and
# (b) that the emitted tags/classes/attributes match by real CSS selectors and
# resolve back to the originating widget via `data-uid`.

private def uid_of(node)
  node["data-uid"]?.try(&.val)
end

describe "CSS (#to_html)" do
  it "derives the type-chain classes from the widget hierarchy" do
    # Button < Input < Box < Widget
    Widget::Button.new.css_type_classes.should eq ["w-button", "w-input", "w-box", "w-widget"]
    Widget::Box.new.css_type_classes.should eq ["w-box", "w-widget"]
    Widget.new.css_type_classes.should eq ["w-widget"]
  end

  it "appends user classes after the type chain" do
    w = Widget::Box.new
    w.css_classes << "danger"
    w.css_all_classes.should eq ["w-box", "w-widget", "danger"]
  end

  it "emits uid as data-uid and the optional css_id as id" do
    w = Widget::Box.new
    w.css_id = "main"
    html = w.to_html
    html.should contain %(data-uid="#{w.uid}")
    html.should contain %(id="main")
    html.should start_with "<w-box"
  end

  it "omits id when css_id is unset" do
    Widget::Box.new.to_html.should_not contain %( id=")
  end

  it "produces a document matchable by real CSS selectors, resolvable back via data-uid" do
    form = Widget::Form.new
    button = Widget::Button.new
    check = Widget::CheckBox.new
    form.append button
    form.append check

    doc = HTML5.parse(form.to_html)

    # type-chain selector matches every Input subclass
    inputs = doc.css(".w-input").to_a
    inputs.map { |node| uid_of node }.to_set.should eq [button.uid.to_s, check.uid.to_s].to_set

    # exact leaf type
    doc.css(".w-button").map { |node| uid_of node }.to_a.should eq [button.uid.to_s]

    # descendant combinator + writeback key resolves to the right widget
    matched = doc.css(".w-form .w-checkbox").to_a
    matched.size.should eq 1
    uid_of(matched.first).should eq check.uid.to_s
  end

  it "escapes attribute values" do
    w = Widget::Box.new
    w.css_id = %(a"b&c<d)
    w.to_html.should contain %(id="a&quot;b&amp;c&lt;d")
  end
end
