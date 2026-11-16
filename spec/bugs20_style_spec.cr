require "./spec_helper"

include Crysterm

describe "selector lists split at top-level commas only" do
  it "keeps a comma inside :has(...) with its selector" do
    sheet = Crysterm::CSS::Stylesheet.parse(".host:has(.a, .b) { color: red; }")
    sheet.rules.size.should eq 1
    sheet.rules[0].selector.should eq ".host"
    sheet.rules[0].has.should eq ".a, .b"
  end

  it "keeps a comma inside a quoted attribute value with its selector" do
    sheet = Crysterm::CSS::Stylesheet.parse(%(Box[title="a,b"] { color: red; }))
    sheet.rules.size.should eq 1
  end

  it "still splits a plain selector list" do
    sheet = Crysterm::CSS::Stylesheet.parse("Box, Label { color: red; }")
    sheet.rules.map(&.selector).should eq [".Box", ".Label"]
  end

  it "matches a :has() selector list against the tree" do
    s = headless_screen(40, 10)
    host = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    plain = Widget::Box.new parent: s, top: 5, left: 0, width: 20, height: 5
    inner = Widget::Box.new parent: host, top: 0, left: 0, width: 5, height: 1
    Widget::Box.new parent: plain, top: 0, left: 0, width: 5, height: 1
    host.add_css_class "host"
    plain.add_css_class "host"
    inner.add_css_class "b"
    without_default_theme do
      s.stylesheet = ".host:has(.a, .b) { color: red; }"
      s.apply_stylesheet
      host.styles.normal.fg.should eq rgb("red")
      plain.styles.normal.fg.nil?.should be_true
    end
  end
end

describe "CSS layout-engine declarations are order-independent" do
  it "configures a flex engine declared after its direction and gap" do
    s = headless_screen(60, 20)
    box = Widget::Box.new parent: s, width: 30, height: 10
    without_default_theme do
      s.stylesheet = "Box { flex-direction: column; gap: 2; display: flex; }"
      s.apply_stylesheet
      engine = box.layout
      engine.is_a?(Layout::Box).should be_true
      engine.as(Layout::Box).orientation.vertical?.should be_true
      engine.as(Layout::Box).spacing.should eq 2

      # A recascade resets the widget to its pre-CSS geometry first, so the
      # same order dependence would recur on every later cascade.
      s.restyle
      box.add_css_class "again"
      s.apply_stylesheet
      engine = box.layout
      engine.is_a?(Layout::Box).should be_true
      engine.as(Layout::Box).orientation.vertical?.should be_true
      engine.as(Layout::Box).spacing.should eq 2
    end
  end

  it "configures a grid engine declared after its track list" do
    s = headless_screen(60, 20)
    box = Widget::Box.new parent: s, width: 30, height: 10
    without_default_theme do
      s.stylesheet = "Box { grid-template-columns: 1fr 1fr 1fr; display: grid; }"
      s.apply_stylesheet
      engine = box.layout
      engine.is_a?(Layout::Grid).should be_true
      engine.as(Layout::Grid).columns.should eq 3
    end
  end
end

describe "box-shadow offsets" do
  it "saturates an absurd offset instead of raising" do
    st = Style.new
    Crysterm::CSS::Properties.apply(st, "box-shadow", "99999999999px 1px")
    st.shadow.right.should eq 1_000_000
    st.shadow.bottom.should eq 1
  end
end

describe "frozen zero boxes" do
  it "dup to a mutable copy" do
    Padding::ZERO.dup.frozen?.should be_false
    Margin::ZERO.dup.frozen?.should be_false
    Border::ZERO.dup.frozen?.should be_false
    Shadow::ZERO.dup.frozen?.should be_false
    Padding::ZERO.frozen?.should be_true
  end

  it "let the cascade apply a longhand over a style assigned the shared zero" do
    s = headless_screen(40, 10)
    box = Widget::Box.new parent: s, width: 10, height: 3
    box.styles.normal.padding = Padding::ZERO
    without_default_theme do
      s.stylesheet = "Box { padding-left: 2; }"
      s.apply_stylesheet
      box.styles.normal.padding.left.should eq 2
      Padding::ZERO.left.should eq 0
    end
  end
end

describe "CSS patch tracking without active rules" do
  it "does not retain state-changed widgets while nothing can cascade" do
    s = headless_screen(40, 10)
    box = Widget::Box.new parent: s, width: 10, height: 3
    without_default_theme do
      box.state = WidgetState::Hovered
      box.state = WidgetState::Normal
      s.@css_patch_widgets.empty?.should be_true
    end
  end

  it "drops the tracking when the rules go away, and restyles from the live tree" do
    s = headless_screen(40, 10)
    box = Widget::Box.new parent: s, width: 10, height: 3
    without_default_theme do
      s.stylesheet = "Box { color: red; }"
      s.apply_stylesheet
      box.styles.normal.fg.should eq rgb("red")
      box.state = WidgetState::Hovered

      s.stylesheet = nil
      s.apply_stylesheet
      box.state = WidgetState::Normal
      box.add_css_class "hot"
      s.apply_stylesheet
      s.@css_patch_widgets.empty?.should be_true

      s.stylesheet = ".hot { color: blue; }"
      s.apply_stylesheet
      box.styles.normal.fg.should eq rgb("blue")
    end
  end
end

describe "Window#stylesheet = nil with add_stylesheet layers" do
  it "drops the layers' custom properties along with the layers" do
    s = headless_screen(40, 10)
    box = Widget::Box.new parent: s, width: 10, height: 3
    without_default_theme do
      s.add_stylesheet "Box { --accent: red; }"
      box.stylesheet = "Box { color: var(--accent, blue); }"
      s.apply_stylesheet
      box.styles.normal.fg.should eq rgb("red")

      s.stylesheet = nil
      s.apply_stylesheet
      box.styles.normal.fg.should eq rgb("blue")
    end
  end
end

describe "Window#css_keyframes" do
  it "finds keyframes defined in an add_stylesheet layer" do
    s = headless_screen(40, 10)
    s.stylesheet = "Box { color: red; }"
    s.add_stylesheet "@keyframes layered { from { opacity: 0; } to { opacity: 1; } }"
    s.css_keyframes("layered").nil?.should be_false
  end

  it "finds keyframes defined in a widget's own stylesheet" do
    s = headless_screen(40, 10)
    box = Widget::Box.new parent: s, width: 10, height: 3
    box.stylesheet = "@keyframes own { from { opacity: 0; } to { opacity: 1; } }"
    s.apply_stylesheet
    s.css_keyframes("own").nil?.should be_false
  end
end

describe "Window#stylesheet= replaces the author sheet" do
  it "does not bring a cleared text sheet back on a later inline recompose" do
    s = headless_screen(40, 10)
    box = Widget::Box.new parent: s, width: 10, height: 3
    box.css_id = "x"
    without_default_theme do
      s.stylesheet = "#x { color: red; }"
      s.stylesheet = nil
      s.add_inline_stylesheet "#y { color: green; }"
      s.apply_stylesheet
      box.styles.normal.fg.nil?.should be_true
    end
  end

  it "does not layer a text sheet over the object sheet it replaced" do
    s = headless_screen(40, 10)
    box = Widget::Box.new parent: s, width: 10, height: 3
    box.css_id = "x"
    without_default_theme do
      s.stylesheet = Crysterm::CSS::Stylesheet.parse("#x { color: red; }")
      s.stylesheet = "#x { background-color: blue; }"
      s.apply_stylesheet
      box.styles.normal.fg.nil?.should be_true
      box.styles.normal.bg.should eq rgb("blue")
    end
  end

  it "does not bring a replaced text sheet back under an object sheet" do
    s = headless_screen(40, 10)
    box = Widget::Box.new parent: s, width: 10, height: 3
    box.css_id = "x"
    without_default_theme do
      s.stylesheet = "#x { color: red; }"
      s.stylesheet = Crysterm::CSS::Stylesheet.parse("#x { background-color: blue; }")
      s.add_inline_stylesheet "#y { color: green; }"
      s.apply_stylesheet
      box.styles.normal.fg.nil?.should be_true
      box.styles.normal.bg.should eq rgb("blue")
    end
  end
end
