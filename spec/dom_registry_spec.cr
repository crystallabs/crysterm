require "./spec_helper"

{% if flag?(:remote) %}
  include Crysterm

  # Invariant: EVERY widget that opted into the layout DOM (auto-discovered into
  # `DOM::REGISTRY`) must survive a serialize -> load -> serialize round-trip
  # unchanged. The loop runs at example time (the registry is filled by a
  # `macro finished` sweep that lands at program start, after spec *collection*),
  # so adding a new widget under `Crysterm::Widget::` automatically subjects
  # it to the check — any asymmetry between `#dom_attributes` and `#dom_apply`,
  # for any registered widget, fails here.

  private def headless_screen
    Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
  end

  describe "DOM::REGISTRY round-trip invariant" do
    it "discovered the expected core widgets" do
      %w[box label button checkbox radiobutton form list plaintextedit lineedit progressbar].each do |tag|
        Crysterm::DOM.registry.has_key?(tag).should be_true
      end
    end

    it "round-trips every registered widget losslessly" do
      failures = [] of String

      Crysterm::DOM.registry.each do |tag, factory|
        begin
          build = headless_screen
          w = factory.call(build)
          build.append w
          w.css_id = "x"
          w.top = 1
          w.left = 2
          w.width = 10
          w.height = 4
          w.set_content "hi"

          first = w.to_layout_html

          reload = headless_screen
          reload.load_layout first
          second = reload.children.first.to_layout_html

          failures << "#{tag}: not stable\n--- first ---\n#{first}--- second ---\n#{second}" unless second == first
        rescue ex
          failures << "#{tag}: raised #{ex.class}: #{ex.message}"
        end
      end

      fail failures.join("\n\n") unless failures.empty?
    end
  end
{% end %}
