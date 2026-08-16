require "./spec_helper"

include Crysterm

# Core-object-model polish. Covers the surface added or reshaped by it:
#   * `Widget#text` / `#text=` (the getter `set_text` never had; plain-text
#     semantics — inline SGR stripped, tags kept literal)
#   * `Widget#lift` (the `#lower` counterpart, spelled `lift` because `raise`
#     is Crystal's own)
#   * `Widget#contents_margins=` delegating to `style.padding`
#   * `Screen#size` / `#geometry`
#   * `#to_s` / `#inspect` on Widget / Window / Screen
#   * `Screen#color_count` memoization staying honest across a config change
#     (and `Screen#colors` being gone)
#   * `Mixin::LineContent` living on `Box`, not on the `Widget` base
#   * the no-arg `Application#exec`

describe "Widget#text / #text=" do
  it "reads back what was set, and equals #content" do
    s = headless_screen(80, 24)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3
    b.text = "hello"
    b.text.should eq "hello"
    b.content.should eq "hello"
  end

  it "strips inline SGR out of the assigned value (plain-text setter)" do
    s = headless_screen(80, 24)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3
    b.text = "\e[31mred\e[0m"
    b.text.should eq "red"
  end

  it "keeps tags literal, unlike #content=" do
    s = headless_screen(80, 24)
    plain = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3,
      parse_tags: true
    plain.text = "{bold}hi{/bold}"
    s.repaint
    # Stored verbatim and rendered verbatim: `set_text` opts the widget into
    # `no_tags`, so the braces are not consumed as markup.
    plain.text.should eq "{bold}hi{/bold}"
    plain.rendered_text.should contain "{bold}"
  end

  it "is overridden by the markup-bearing subclasses (Label keeps tags)" do
    s = headless_screen(80, 24)
    l = Widget::Label.new parent: s, top: 0, left: 0, width: 20, height: 3,
      parse_tags: true
    l.text = "{bold}hi{/bold}"
    s.repaint
    l.text.should eq "{bold}hi{/bold}"
    l.rendered_text.should eq "hi"
  end
end

describe "Widget#lift / #lower" do
  it "lift is to_front and lower is to_back" do
    s = headless_screen(80, 24)
    a = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 2
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 2
    s.children.last.same?(b).should be_true
    a.lift
    s.children.last.same?(a).should be_true
    a.lower
    s.children.first.same?(a).should be_true
  end
end

describe "Widget#contents_margins=" do
  it "writes through to style.padding" do
    s = headless_screen(80, 24)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    b.contents_margins = 2
    b.style.padding.left.should eq 2
    b.style.padding.top.should eq 2
    # With no border, the reported contents margins are exactly the padding.
    b.contents_margins.left.should eq 2
    b.contents_margins.bottom.should eq 2
  end
end

describe "Screen#size / #geometry" do
  it "reports the device extent as value objects" do
    s = headless_screen(40, 12)
    dev = s.screen
    dev.size.should eq Crysterm::Size.new(dev.width, dev.height)
    g = dev.geometry
    g.x.should eq 0
    g.y.should eq 0
    g.width.should eq dev.width
    g.height.should eq dev.height
  end
end

describe "#to_s / #inspect" do
  it "identifies a widget by class, uid, name and geometry" do
    s = headless_screen(80, 24)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5,
      name: "sidebar"
    s.repaint
    str = b.to_s
    str.should start_with "Box##{b.uid}"
    str.should contain %("sidebar")
    str.should contain "20x5@(0,0)"
    b.inspect.should eq "#<#{str}>"
  end

  it "omits the name when unset" do
    s = headless_screen(80, 24)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 4, height: 2
    b.to_s.should_not contain '"'
  end

  it "identifies a window and a screen" do
    s = headless_screen(40, 12)
    s.name = "main"
    s.to_s.should eq %(Window "main" 40x12)
    s.screen.to_s.should eq "Screen 40x12"
    s.screen.inspect.should eq "#<Screen 40x12>"
  end
end

describe "Screen#color_count" do
  it "is memoized but still tracks a runtime config change" do
    s = headless_screen(20, 5)
    dev = s.screen
    prev = Crysterm::Config.colors_depth
    begin
      Crysterm::Config.colors_depth = Crysterm::ColorDepth::Xterm256
      dev.color_count.should eq 256
      dev.color_count.should eq 256 # memo hit
      Crysterm::Config.colors_depth = Crysterm::ColorDepth::Ansi
      dev.color_count.should eq 16 # invalidated by the config change
    ensure
      Crysterm::Config.colors_depth = prev
    end
  end

  it "no longer answers to the removed #colors alias" do
    s = headless_screen(20, 5)
    s.screen.responds_to?(:colors).should be_false
    s.responds_to?(:colors).should be_false
  end
end

describe "Mixin::LineContent" do
  it "is on Box (and its descendants), not on the Widget base" do
    Widget::Box.new.responds_to?(:append_line).should be_true
    Widget::Log.new.responds_to?(:append_line).should be_true
    Widget.new.responds_to?(:append_line).should be_false
    Widget::Spacer.new.responds_to?(:append_line).should be_false
  end

  it "still edits logical lines through the mixin" do
    s = headless_screen(80, 24)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5,
      content: "one\ntwo"
    s.repaint
    b.append_line "three"
    b.lines.should eq ["one", "two", "three"]
    b.replace_line 1, "TWO"
    b.lines.should eq ["one", "TWO", "three"]
    b.delete_line 0, 1
    b.lines.should eq ["TWO", "three"]
  end
end

describe "Crysterm::Unicode text helpers" do
  it "measures SGR-free display width without a widget" do
    Crysterm::Unicode.str_width("\e[31mabc\e[0m", false).should eq 3
    Crysterm::Unicode.str_width("你好", true).should eq 4
    Crysterm::Unicode.wrap_cut_index("abcdef", 3, false).should eq 3
    Crysterm::Unicode.head_within("abcdef", 3, true).should eq "abc"
    Crysterm::Unicode.tail_within("abcdef", 3, true).should eq "def"
  end

  it "agrees with the Widget-side forwarders" do
    s = headless_screen(80, 24)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 3
    b.str_width("\e[31mabc\e[0m").should eq Crysterm::Unicode.str_width("\e[31mabc\e[0m", b.full_unicode?)
    b.wrap_cut_index("abcdef", 3).should eq Crysterm::Unicode.wrap_cut_index("abcdef", 3, b.full_unicode?)
  end
end

describe "Application#exec with no arguments" do
  it "raises when no window is registered" do
    app = Application.new
    expect_raises(ArgumentError, /no windows registered/) { app.exec }
  end
end

describe "Window.open / Window.run are the canonical class entry points" do
  it "no longer exist on Application" do
    Application.responds_to?(:open).should be_false
    Application.responds_to?(:run).should be_false
    Window.responds_to?(:open).should be_true
    Window.responds_to?(:run).should be_true
  end
end
