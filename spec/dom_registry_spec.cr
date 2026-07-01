require "./spec_helper"

{% if flag?(:remote) %}
  include Crysterm

  # Invariant: every widget auto-discovered into `DOM::REGISTRY` must survive a
  # serialize -> load -> serialize round-trip unchanged. The registry is filled
  # by a `macro finished` sweep at program start (after spec collection), so
  # any new `Crysterm::Widget::` is automatically checked — any asymmetry
  # between `#dom_attributes` and `#dom_apply` fails here.

  private def headless_screen
    Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
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

    # A string option with a non-empty constructor default (e.g.
    # `ProgressBar#text_format = "%p%"`) must round-trip when cleared to "".
    # The auto-serializer previously skipped empty strings, so a cleared value
    # silently reverted to the default on reload.
    it "round-trips a non-empty-default string option cleared to empty" do
      s = headless_screen
      pb = Crysterm::Widget::ProgressBar.new window: s
      s.append pb
      pb.css_id = "p"
      pb.text_format.should eq "%p%" # sanity: non-empty default
      pb.text_format = ""            # user clears it

      reload = headless_screen
      reload.load_layout s.to_layout_html
      loaded = reload.find_by_id("p").as(Crysterm::Widget::ProgressBar)
      loaded.text_format.should eq ""
    end
  end
{% end %}
