require "./spec_helper"

{% if flag?(:remote) %}
  include Crysterm

  private def headless_screen
    Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
  end

  private def rgb(name)
    Crysterm::Colors.convert(name).to_i32
  end

  # A `<style>` block in the HTML is extracted and handed to the same CSS
  # parser/cascade, so one file can carry structure + appearance.
  describe "inline <style> in a layout" do
    it "applies CSS from an inline <style> block" do
      s = headless_screen
      s.load_layout <<-HTML
      <w-window>
        <style>
          #hello { color: red; }
        </style>
        <w-box id="hello"></w-box>
      </w-window>
      HTML
      s.apply_stylesheet

      s.find_by_id("hello").not_nil!.styles.normal.fg.should eq rgb("red")
    end

    it "composes inline styles after an external stylesheet (inline wins on ties)" do
      s = headless_screen
      s.stylesheet = "#hello { color: red; }"
      s.load_layout %(<w-window><style>#hello { color: blue; }</style><w-box id="hello"></w-box></w-window>)
      s.apply_stylesheet

      s.find_by_id("hello").not_nil!.styles.normal.fg.should eq rgb("blue")
    end

    it "does not build the <style> element as a widget" do
      s = headless_screen
      s.load_layout %(<w-window><style>Box{color:red}</style><w-box id="a"></w-box></w-window>)
      s.children.size.should eq 1
      s.children.first.css_id.should eq "a"
    end

    it "re-applies inline styles after a hot-reload" do
      s = headless_screen
      s.load_layout %(<w-window><style>#x{color:red}</style><w-box id="x"></w-box></w-window>)
      bridge = Crysterm::HTTPBridge.new(s, port: 7106)
      bridge.start
      s.apply_stylesheet
      s.find_by_id("x").not_nil!.styles.normal.fg.should eq rgb("red")

      bridge.reload_layout %(<w-window><style>#x{color:green}</style><w-box id="x"></w-box></w-window>)
      s.apply_stylesheet
      s.find_by_id("x").not_nil!.styles.normal.fg.should eq rgb("green")
    end
  end
{% end %}
