require "./spec_helper"

# Regression specs for BUGS18 B18-105: the layout-DOM serializer/loader treated
# ActionBar-family bars (CommandBar / MenuBar / ToolBar) as ordinary containers —
# a snapshot serialized their macro-built item boxes as `<w-box>` children, and
# a reload rebuilt those as plain dead widgets with an empty command model (a
# lookalike but completely dead bar). Via `Widget#dom_owns_children?`,
# the serializer must skip descending into model-owned children and emit the
# command model as an `items` attribute instead; the loader rebuilds through
# `#add_item` and skips serialized child nodes (including the ghost `<w-box>`
# children of older snapshots). Guarded by -Dremote like the other layout-DOM
# specs; run with:
#   crystal spec -Dremote spec/bugs18_dom_bars_spec.cr
{% if flag?(:remote) %}
  include Crysterm

  describe "BUGS18 B18-105 layout-DOM round-trip for ActionBar bars" do
    it "serializes a CommandBar's command model as an items attribute, not <w-box> children" do
      s = headless_screen(80, 24, default_quit_keys: true)
      bar = Widget::CommandBar.new(parent: s, top: 0, left: 0, width: 60, height: 1)
      bar.add_item("Open") { }
      bar.add_item("Save") { }
      bar.add_item("Quit") { }

      html = s.to_layout_html
      html.should contain %(<w-commandbar)
      html.should contain %(items="Open\nSave\nQuit")
      # The bar is childless in the markup — its item boxes are model-owned,
      # not reconstructable children, and no command may leak out as a dead
      # <w-box content="…1…:Open"> child.
      html.should_not contain "<w-box"
    end

    it "reloads a CommandBar with a live command model and no orphan dead child boxes" do
      s = headless_screen(80, 24, default_quit_keys: true)
      bar = Widget::CommandBar.new(parent: s, top: 0, left: 0, width: 60, height: 1)
      bar.add_item("Open") { }
      bar.add_item("Save") { }
      bar.add_item("Quit") { }

      s2 = headless_screen(80, 24, default_quit_keys: true)
      s2.load_layout s.to_layout_html
      bar2 = s2.children.first.as(Widget::CommandBar)

      # Live model, not ghosts: commands/item_boxes must be populated rather
      # than two dead plain Boxes carrying the labels.
      bar2.items.size.should eq 3
      bar2.item_texts.should eq %w[Open Save Quit]
      bar2.item_boxes.size.should eq 3
      # Every child is a model-backed item box — no extra dead boxes.
      bar2.children.size.should eq 3
      bar2.children.should eq bar2.item_boxes.map &.as(Widget)

      # Activation is wired: selecting/firing routes through the rebuilt model
      # (on an empty @commands, activate_item would be a silent no-op).
      activated = [] of Int32
      bar2.on(Crysterm::Event::ItemActivated) { |e| activated << e.index }
      bar2.activate_item 1
      activated.should eq [1]
      bar2.current_index.should eq 1
    end

    it "keeps the round-trip idempotent: serialize -> load -> serialize" do
      s = headless_screen(80, 24, default_quit_keys: true)
      bar = Widget::CommandBar.new(parent: s, top: 0, left: 0, width: 60, height: 1)
      bar.add_item("Open") { }
      bar.add_item("Quit") { }

      first = s.to_layout_html
      s2 = headless_screen(80, 24, default_quit_keys: true)
      s2.load_layout first
      s2.to_layout_html.should eq first
    end

    it "gracefully drops the ghost <w-box> children of a pre-fix snapshot" do
      s = headless_screen(80, 24, default_quit_keys: true)
      # Shape of an old snapshot: item boxes serialized as children alongside
      # nothing else. The loader must not attach them as dead children.
      s.load_layout <<-HTML
        <w-window>
          <w-commandbar id="bar" width="60" height="1" items="Open\nQuit">
            <w-box content="1:Open"></w-box>
            <w-box content="2:Quit"></w-box>
          </w-commandbar>
        </w-window>
        HTML

      bar = s.find_by_id("bar").not_nil!.as(Widget::CommandBar)
      bar.item_texts.should eq %w[Open Quit]
      # Only the two model-backed item boxes — the ghost <w-box> nodes were
      # skipped, not appended on top.
      bar.children.size.should eq 2
      bar.children.should eq bar.item_boxes.map &.as(Widget)
    end

    it "round-trips a MenuBar's titles as a live model too" do
      s = headless_screen(80, 24, default_quit_keys: true)
      bar = Widget::MenuBar.new(parent: s, top: 0, left: 0, width: 60, height: 1)
      bar.add_item("File") { }
      bar.add_item("Edit") { }

      html = s.to_layout_html
      html.should contain %(<w-menubar)
      html.should contain %(items="File\nEdit")
      html.should_not contain "<w-box"

      s2 = headless_screen(80, 24, default_quit_keys: true)
      s2.load_layout html
      bar2 = s2.children.first.as(Widget::MenuBar)
      bar2.item_texts.should eq %w[File Edit]
      bar2.items.size.should eq 2
      bar2.children.size.should eq 2
      s2.to_layout_html.should eq html
    end
  end
{% end %}
