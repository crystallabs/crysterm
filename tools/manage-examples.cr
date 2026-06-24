#!/usr/bin/env crystal
#
# widget-examples.cr — maintenance tool that standardizes how every Crysterm
# widget is exemplified and screenshotted.
#
# For each widget under `src/widget/`, it:
#
#   1. Mirrors the source hierarchy into `examples/widget/` and gives the widget
#      its own directory, e.g.
#          src/widget/button.cr      -> examples/widget/button/
#          src/widget/graph/bar.cr   -> examples/widget/graph/bar/
#   2. Writes one (or, rarely, several) *minimal* example(s) into that directory,
#      each named after the widget — `button.cr`, or `button2.cr`, `button3.cr`
#      when a widget genuinely needs alternative examples. Existing files are
#      left untouched unless `--force` is given.
#   3. Renders the example headlessly and saves a screenshot beside it as
#      `<widget>-capture.png` (or `-capture2.png`, ... for further examples), via
#      `Screen#capture`, driven through the shared harness in
#      `examples/widget/example.cr` with `CRYSTERM_SHOT`.
#   4. On `--doc-comments`, embeds each widget's screenshot in its API docs by
#      maintaining a fenced block in the class's source doc comment; on `--docs`,
#      runs `crystal docs` and copies `examples/widget/` into the docs tree so
#      those references resolve.
#
# This is meant to be groomed and extended over time: add or refine per-widget
# recipes in `RECIPES` below; later additions might emit usage animations (APNG —
# `Screen#capture` already does it via `duration:`), or run verification passes
# (does every widget still have an example? does each example still build?).
#
# Usage:
#   crystal run tools/widget-examples.cr -- [options] [widget ...]
#
# Options:
#   -f, --force         Overwrite/recreate existing example files (default: skip
#                       existing ones; only fill in what is missing).
#       --only NAME     Restrict to widget(s) whose name matches NAME (repeatable;
#                       bare arguments are treated the same way). Matches the
#                       widget's file basename or class name, case-insensitively.
#       --no-shot       Generate/refresh example files but skip the screenshots.
#       --shots-only    Don't (re)generate files; only (re)take screenshots of
#                       the examples that already exist.
#   -j, --jobs N        Screenshot concurrency (default: ~cores-1, capped at 4).
#                       Each shot is a full compile, so this is the main speedup.
#       --doc-comments  Insert/refresh the screenshot block in each widget's
#                       source class doc comment (idempotent; migrates old blocks).
#       --docs          Run `crystal docs`, then copy examples/widget into docs/.
#       --list          List the discovered widgets and what would happen, then
#                       exit (no files written, no screenshots taken).
#   -h, --help          This help.
#
# Examples:
#   crystal run tools/widget-examples.cr --                 # fill in everything missing + shoot
#   crystal run tools/widget-examples.cr -- --list          # see the plan
#   crystal run tools/widget-examples.cr -- box button      # just these two
#   crystal run tools/widget-examples.cr -- --force calendar # rebuild calendar's example
#   crystal run tools/widget-examples.cr -- --doc-comments  # maintain doc-comment screenshots
#   crystal run tools/widget-examples.cr -- --docs          # build API docs with screenshots

require "file_utils"

module WidgetExamples
  VERSION = "0.1.0"

  # ---- locations ------------------------------------------------------------

  ROOT       = File.expand_path(File.join(__DIR__, ".."))
  WIDGETS_CR = File.join(ROOT, "src", "widgets.cr")
  # The single shared example harness; every generated example requires it.
  HELPER = File.join(ROOT, "examples", "widget", "example")

  # ---- kinds ----------------------------------------------------------------

  # A category of documented thing the tool mirrors and exemplifies the same way.
  # `widget`s render standalone; `layout`s are installed on a container and
  # arrange its children (so their examples differ — see the recipes).
  record Kind,
    name : String,    # "widget" / "layout"
    src : String,     # src dir, e.g. <root>/src/widget
    out_dir : String, # output dir, e.g. <root>/examples/widget
    base_ns : String  # "Crysterm::Widget" / "Crysterm::Layout"

  KINDS = [
    Kind.new("widget", File.join(ROOT, "src", "widget"), File.join(ROOT, "examples", "widget"), "Crysterm::Widget"),
    Kind.new("layout", File.join(ROOT, "src", "layout"), File.join(ROOT, "examples", "layout"), "Crysterm::Layout"),
  ]

  # ---- a discovered item ----------------------------------------------------

  # One instantiable widget or layout: its kind, where its source lives, its
  # class, and where its example(s) go.
  record Item,
    kind : Kind,
    klass : String,   # simple class name, e.g. "Box", "Bar", "HBox"
    fqn : String,     # "Crysterm::Widget::Graph::Bar" / "Crysterm::Layout::HBox"
    src : String,     # absolute path to the source .cr
    rel : String,     # path under the kind's src dir, no ext, e.g. "graph/bar"
    basename : String # "bar"

  # The example directory for an item: examples/<kind>/<rel>/
  def self.example_dir(w : Item) : String
    File.join(w.kind.out_dir, w.rel)
  end

  # `require` path from an example file back to the shared harness, computed
  # relative to the example's own directory (so it works from either tree, at any
  # nesting — e.g. "../example", "../../example", "../../widget/example").
  def self.helper_require(w : Item) : String
    relpath(example_dir(w), HELPER)
  end

  # POSIX relative path from directory *from* to file/dir *to* (both absolute).
  def self.relpath(from : String, to : String) : String
    f = from.split('/').reject(&.empty?)
    t = to.split('/').reject(&.empty?)
    i = 0
    while i < f.size && i < t.size && f[i] == t[i]
      i += 1
    end
    ([".."] * (f.size - i) + t[i..]).join('/')
  end

  # ---- recipes --------------------------------------------------------------

  # A single example to emit for a widget: an optional CSS stylesheet and the
  # body that constructs the widget(s) inside the `WidgetExample.run` block.
  # `%{fqn}` / `%{klass}` / `%{name}` are interpolated.
  record Recipe, css : String?, body : String

  # The fallback used when a widget has no entry in RECIPES: a plain Box-style
  # construction. It compiles for the many widgets that inherit Box's `content:`
  # constructor.
  #
  # It fills (almost) the whole screen on purpose. Many widgets lay out their own
  # fixed-position children (ColorDialog, Wizard, ...); a small box would let
  # those children spill past its border and paint garbage onto the screen. A
  # full-screen box keeps them in bounds, so the generic shot is never broken —
  # just plain. Widgets that deserve a tailored size/content get a real recipe in
  # WIDGET_RECIPES (and are reported until they do).
  def self.generic_widget_recipe(w : Item) : Recipe
    Recipe.new(
      css: "#{w.klass} { border: solid; }",
      body: <<-CR
        %{fqn}.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          content: "{center}%{klass}{/center}", parse_tags: true
      CR
    )
  end

  # Per-widget recipes. Keyed by simple class name. A widget maps to an array so
  # it can have alternative examples (foo.cr, foo2.cr, ...). Most widgets need
  # only one. Add entries here as widgets are groomed.
  WIDGET_RECIPES = {
    "Box" => [Recipe.new(
      css: "Box { border: solid; background-color: #1a1a2e; color: #e0e0e0; }",
      body: <<-CR
        %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 34, height: 7,
          content: "{center}A Box widget{/center}", parse_tags: true
      CR
    )],
    "Label" => [Recipe.new(
      css: "Label { color: #9ece6a; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "center", left: "center", content: "A Label widget"
      CR
    )],
    "Button" => [Recipe.new(
      css: "Button { border: solid; background-color: #394b70; color: #c0caf5; }",
      body: <<-CR
        %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 22, height: 3,
          content: "{center}Click me{/center}", parse_tags: true
      CR
    )],
    "ProgressBar" => [Recipe.new(
      css: "ProgressBar { border: solid; color: #7aa2f7; }",
      body: <<-CR
        bar = %{fqn}.new parent: screen, top: "center", left: "center", width: 40, height: 3
        bar.value = 65
      CR
    )],
    "HLine" => [Recipe.new(
      css: "HLine { color: #7aa2f7; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "center", left: 4, width: 40
      CR
    )],
    "VLine" => [Recipe.new(
      css: "VLine { color: #7aa2f7; }",
      body: <<-CR
        %{fqn}.new parent: screen, left: "center", top: 2, height: 16
      CR
    )],
    "BigText" => [Recipe.new(
      css: "BigText { color: #f7768e; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "center", left: "center", content: "Hi!"
      CR
    )],
    "List" => [Recipe.new(
      css: "List { border: solid; color: #c0caf5; }",
      body: <<-CR
        %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 28, height: 9,
          items: %w[Alpha Beta Gamma Delta Epsilon]
      CR
    )],
    "Log" => [Recipe.new(
      css: "Log { border: solid; color: #9ece6a; }",
      body: <<-CR
        log = %{fqn}.new parent: screen, top: "center", left: "center", width: 46, height: 9
        ["system started", "loading config", "ready", "request handled"].each { |l| log.add l }
      CR
    )],
    "Gauge" => [Recipe.new(
      css: "Gauge { border: solid; color: #7aa2f7; }",
      body: <<-CR
        g = %{fqn}.new parent: screen, top: "center", left: "center", width: 40, height: 3
        g.value = 65
      CR
    )],
    "GaugeList" => [Recipe.new(
      css: "GaugeList { border: solid; }",
      body: <<-CR
        gl = %{fqn}.new parent: screen, top: "center", left: "center", width: 46, height: 9
        gl.add_gauge "CPU", 72
        gl.add_gauge "Memory", 48
        gl.add_gauge "Disk", 91
      CR
    )],
    "Checkbox" => [Recipe.new(
      css: "Checkbox { color: #c0caf5; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "center", left: "center", checked: true, content: "Enable feature"
      CR
    )],
    "RadioButton" => [Recipe.new(
      css: "RadioButton { color: #c0caf5; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "50%-1", left: "center", content: "Selected option"
      CR
    )],
    "Slider" => [Recipe.new(
      css: "Slider { color: #bb9af7; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "center", left: "center", width: 40, height: 1, value: 40
      CR
    )],
    "SpinBox" => [Recipe.new(
      css: "SpinBox { border: solid; color: #c0caf5; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "center", left: "center", width: 14, height: 3, value: 42
      CR
    )],
    "LCDNumber" => [Recipe.new(
      css: "LCDNumber { color: #f7768e; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "center", left: "center", value: 1234
      CR
    )],
    "Calendar" => [Recipe.new(
      css: "Calendar { border: solid; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "center", left: "center", date: Time.utc(2026, 6, 24)
      CR
    )],
    "Marquee" => [Recipe.new(
      css: "Marquee { color: #e0af68; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "center", left: "center", width: 40, height: 1, text: "Scrolling marquee text — Crysterm"
      CR
    )],
    "ColorDialog" => [Recipe.new(
      css: "ColorDialog { border: solid; }",
      body: <<-CR
        # ColorDialog lays out its own gradient field, hue bar and RGB/HSV spin
        # boxes; it wants roughly 56x20 (see the class docs) — too small a box and
        # its children spill past the border.
        %{fqn}.new parent: screen, top: "center", left: "center", width: 56, height: 20
      CR
    )],
    "SplashScreen" => [Recipe.new(
      css: "SplashScreen { border: solid; }",
      body: <<-CR
        # `content` is the central widget shown on the splash (not a string).
        %{fqn}.new \\
          parent: screen, width: 44, height: 12,
          content: Crysterm::Widget::Box.new(
            top: "center", left: "center", width: 28, height: 3,
            content: "{center}Crysterm{/center}", parse_tags: true)
      CR
    )],
    "MessageView" => [Recipe.new(
      css: "MessageView { border: solid; }",
      body: <<-CR
        %{fqn}.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          from: "alice@example.com", to: "bob@example.com",
          date: "2026-06-24", subject: "Hello from Crysterm",
          body: "This is the message body.\\nA Pine-style message view."
      CR
    )],
    "Loading" => [Recipe.new(
      css: "Loading { color: #7dcfff; }",
      body: <<-CR
        l = %{fqn}.new parent: screen, top: "center", left: "center", width: 30, height: 1
        l.load "Loading…"
      CR
    )],
  } of String => Array(Recipe)

  # Per-layout recipes (keyed by simple class name). Each builds a full-screen
  # container with the layout installed and enough labeled children to actually
  # show how that layout arranges them. `%{fqn}` is the layout class.
  BORDERED       = "Box { border: solid; color: #c0caf5; }"
  LAYOUT_RECIPES = {
    "HBox" => [Recipe.new(
      css: BORDERED,
      body: <<-CR
        container = Crysterm::Widget::Box.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          layout: %{fqn}.new(gap: 1), overflow: :ignore
        # Children given no width share the row equally (align: stretch fills height).
        %w[Left Middle Middle Right].each do |label|
          Crysterm::Widget::Box.new parent: container, content: "{center}\#{label}{/center}", parse_tags: true
        end
      CR
    )],
    "VBox" => [Recipe.new(
      css: BORDERED,
      body: <<-CR
        container = Crysterm::Widget::Box.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          layout: %{fqn}.new(gap: 1), overflow: :ignore
        %w[Top Middle Middle Bottom].each do |label|
          Crysterm::Widget::Box.new parent: container, content: "{center}\#{label}{/center}", parse_tags: true
        end
      CR
    )],
    "Grid" => [Recipe.new(
      css: BORDERED,
      body: <<-CR
        # A 3-column grid; the six children auto-flow row-major into the cells.
        container = Crysterm::Widget::Box.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          layout: %{fqn}.new(columns: 3, gap: 1), overflow: :ignore
        6.times do |i|
          Crysterm::Widget::Box.new parent: container,
            content: "{center}r\#{i // 3} · c\#{i % 3}{/center}", parse_tags: true
        end
      CR
    )],
    "UniformGrid" => [Recipe.new(
      css: BORDERED,
      body: <<-CR
        container = Crysterm::Widget::Box.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          layout: %{fqn}.new, overflow: :ignore
        8.times do |i|
          Crysterm::Widget::Box.new parent: container, width: 16, height: 5,
            content: "{center}cell \#{i + 1}{/center}", parse_tags: true
        end
      CR
    )],
    "Masonry" => [Recipe.new(
      css: BORDERED,
      body: <<-CR
        container = Crysterm::Widget::Box.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          layout: %{fqn}.new, overflow: :ignore
        # Varying heights flow into the shortest column — the masonry effect.
        [4, 6, 3, 5, 7, 4, 5, 3].each_with_index do |h, i|
          Crysterm::Widget::Box.new parent: container, width: 16, height: h,
            content: "{center}#\#{i + 1}{/center}", parse_tags: true
        end
      CR
    )],
    "Wrap" => [Recipe.new(
      css: BORDERED,
      body: <<-CR
        container = Crysterm::Widget::Box.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          layout: %{fqn}.new, overflow: :ignore
        %w[alpha beta gamma delta epsilon zeta eta theta iota].each do |label|
          Crysterm::Widget::Box.new parent: container, width: 13, height: 3,
            content: "{center}\#{label}{/center}", parse_tags: true
        end
      CR
    )],
    "Stack" => [Recipe.new(
      css: BORDERED,
      body: <<-CR
        # All three children occupy the full area; only `current` is shown.
        container = Crysterm::Widget::Box.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          layout: %{fqn}.new(current: 1), overflow: :ignore
        3.times do |i|
          Crysterm::Widget::Box.new parent: container,
            content: "{center}page \#{i + 1} of 3\\n\\n(Stack shows current = 1){/center}", parse_tags: true
        end
      CR
    )],
    "Manual" => [Recipe.new(
      css: BORDERED,
      body: <<-CR
        # Manual placement: children position themselves by top/left/right/bottom.
        container = Crysterm::Widget::Box.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          layout: %{fqn}.new, overflow: :ignore
        Crysterm::Widget::Box.new parent: container, top: 1, left: 2, width: 24, height: 4,
          content: "{center}(left: 2, top: 1){/center}", parse_tags: true
        Crysterm::Widget::Box.new parent: container, top: 7, left: 28, width: 26, height: 5,
          content: "{center}(left: 28, top: 7){/center}", parse_tags: true
        Crysterm::Widget::Box.new parent: container, bottom: 1, right: 2, width: 22, height: 4,
          content: "{center}bottom-right{/center}", parse_tags: true
      CR
    )],
    "Border" => [Recipe.new(
      css: BORDERED,
      body: <<-CR
        # Five children, each docked to an edge (or the center) by a Border::Hint.
        container = Crysterm::Widget::Box.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          layout: %{fqn}.new, overflow: :ignore
        Crysterm::Widget::Box.new parent: container, height: 3,
          layout_hint: Crysterm::Layout::Border::Hint.new(:top),
          content: "{center}Top{/center}", parse_tags: true
        Crysterm::Widget::Box.new parent: container, height: 3,
          layout_hint: Crysterm::Layout::Border::Hint.new(:bottom),
          content: "{center}Bottom{/center}", parse_tags: true
        Crysterm::Widget::Box.new parent: container, width: 16,
          layout_hint: Crysterm::Layout::Border::Hint.new(:left),
          content: "{center}Left{/center}", parse_tags: true
        Crysterm::Widget::Box.new parent: container, width: 16,
          layout_hint: Crysterm::Layout::Border::Hint.new(:right),
          content: "{center}Right{/center}", parse_tags: true
        Crysterm::Widget::Box.new parent: container,
          layout_hint: Crysterm::Layout::Border::Hint.new(:center),
          content: "{center}Center{/center}", parse_tags: true
      CR
    )],
    "Form" => [Recipe.new(
      # 1-row fields: no border (it would eat the single content row).
      css: "Box { color: #c0caf5; }",
      body: <<-CR
        # Label/field pairs, one per row; a trailing unpaired child spans full width.
        container = Crysterm::Widget::Box.new \\
          parent: screen, top: 2, left: 2, width: 50, height: 12,
          layout: %{fqn}.new(label_width: 10, row_gap: 1), overflow: :ignore
        { {"Name:", "Ada Lovelace"}, {"Email:", "ada@example.com"}, {"Role:", "Engineer"} }.each do |label, value|
          Crysterm::Widget::Box.new parent: container, height: 1, content: label
          Crysterm::Widget::Box.new parent: container, height: 1, content: value
        end
        Crysterm::Widget::Box.new parent: container, height: 1,
          content: "{center}[ Submit ]{/center}", parse_tags: true
      CR
    )],
  } of String => Array(Recipe)

  # Layouts aren't standalone widgets: each is installed on a container via
  # `layout:` and arranges the container's children. So a layout example builds a
  # full-screen container with the layout, then drops a handful of labeled,
  # bordered child boxes into it — enough to actually *show* the arrangement.
  # Layouts that need per-child placement hints (Grid columns, Border regions,
  # Form rows) get tailored recipes below; the rest flow fine generically.
  def self.generic_layout_recipe(w : Item) : Recipe
    Recipe.new(
      css: "Box { border: solid; color: #c0caf5; }",
      body: <<-CR
        container = Crysterm::Widget::Box.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          layout: %{fqn}.new, overflow: :ignore
        6.times do |i|
          Crysterm::Widget::Box.new \\
            parent: container, width: 16, height: 5,
            content: "{center}%{klass}\\n#\#{i + 1}{/center}", parse_tags: true
        end
      CR
    )
  end

  # The generic example for an item, dispatched by kind.
  def self.generic_recipe(w : Item) : Recipe
    w.kind.name == "layout" ? generic_layout_recipe(w) : generic_widget_recipe(w)
  end

  # The recipe map for an item's kind.
  def self.recipe_map(w : Item) : Hash(String, Array(Recipe))
    w.kind.name == "layout" ? LAYOUT_RECIPES : WIDGET_RECIPES
  end

  # Case-insensitive recipe lookup: a file may declare `CheckBox` while the
  # registry/recipe key is `Checkbox` (Crysterm aliases some constants by case).
  def self.lookup_recipes(w : Item) : Array(Recipe)?
    recipe_map(w).each { |k, v| return v if k.compare(w.klass, case_insensitive: true) == 0 }
    nil
  end

  def self.recipe?(w : Item) : Bool
    !lookup_recipes(w).nil?
  end

  def self.recipes_for(w : Item) : Array(Recipe)
    lookup_recipes(w) || [generic_recipe(w)]
  end

  # ---- discovery ------------------------------------------------------------

  # The set of fully-qualified widget/layout classes Crysterm exposes, parsed
  # from the authoritative `src/widgets.cr` registry (RHS of each
  # `Name = Widget::...` / `Name = Crysterm::Layout::...`). Filename<->class is
  # irregular (lcd_number -> LCDNumber, hline -> HLine), so the registry is the
  # source of truth for *which* classes are real, public widgets/layouts.
  def self.registry : Set(String)
    set = Set(String).new
    File.read_lines(WIDGETS_CR).each do |line|
      if m = line.match(/=\s*((?:Crysterm::)?(?:Widget|Layout)::[A-Za-z0-9_:]+)\s*$/)
        fqn = m[1]
        fqn = "Crysterm::#{fqn}" unless fqn.starts_with?("Crysterm::")
        set << fqn
      end
    end
    set
  end

  # Walk each kind's src tree, and for every file resolve the (one) registered
  # class it defines. A file contributes an Item only if one of the classes it
  # declares, namespaced by the kind plus its directory, is in the registry —
  # which naturally skips abstract bases (media/base.cr, layout/layout.cr ...)
  # and non-public helpers.
  def self.discover : Array(Item)
    reg = registry.map(&.downcase).to_set
    items = [] of Item

    KINDS.each do |kind|
      next unless Dir.exists?(kind.src)
      Dir.glob(File.join(kind.src, "**", "*.cr")).sort.each do |src|
        rel = src[(kind.src.size + 1)..].chomp(".cr") # e.g. "graph/bar"
        dir = File.dirname(rel)
        ns_segments = dir == "." ? [] of String : dir.split('/').map(&.capitalize)
        ns_prefix = ns_segments.empty? ? "" : ns_segments.join("::") + "::"

        # Candidate class names declared in the file (skip the namespace wrapper
        # class, `class Widget` / `class Layout`).
        content = File.read(src)
        chosen : String? = nil
        content.scan(/^\s*class\s+([A-Z][A-Za-z0-9_]*)/m) do |m|
          name = m[1]
          next if "Crysterm::#{name}" == kind.base_ns # the wrapper class itself
          fqn = "#{kind.base_ns}::#{ns_prefix}#{name}"
          if reg.includes?(fqn.downcase)
            chosen = name
            break
          end
        end

        next unless klass = chosen
        fqn = "#{kind.base_ns}::#{ns_prefix}#{klass}"
        items << Item.new(
          kind: kind, klass: klass, fqn: fqn, src: src, rel: rel,
          basename: File.basename(rel))
      end
    end

    items
  end

  # ---- file generation ------------------------------------------------------

  # The numeric suffix for the *index*'th example/screenshot: "" for the first,
  # "2", "3", ... after that.
  def self.suffix(index : Int32) : String
    index == 0 ? "" : (index + 1).to_s
  end

  # The example file paths for a widget, in order (foo.cr, foo2.cr, ...).
  def self.example_paths(w : Item, count : Int32) : Array(String)
    dir = example_dir(w)
    (0...count).map { |i| File.join(dir, "#{w.basename}#{suffix(i)}.cr") }
  end

  # Where the *index*'th example's screenshot goes: `<prog>-capture.png`,
  # `<prog>-capture2.png`, ... in the widget's directory (`<prog>` is the widget
  # name; the number tracks the program index, empty for the first).
  def self.screenshot_path(w : Item, index : Int32) : String
    File.join(example_dir(w), "#{w.basename}-capture#{suffix(index)}.png")
  end

  # Render one example file's full source from a recipe.
  def self.render_example(w : Item, recipe : Recipe, index : Int32, total : Int32) : String
    req = helper_require(w)
    title = w.klass
    interp = ->(s : String) {
      s.gsub("%{fqn}", w.fqn).gsub("%{klass}", w.klass).gsub("%{name}", w.basename)
    }
    body = reindent(interp.call(recipe.body).rstrip, "  ")
    css = recipe.css.try { |c| interp.call(c) }

    String.build do |io|
      label = total > 1 ? " (example #{index + 1} of #{total})" : ""
      io << "# Example: " << w.fqn << label << "\n"
      io << "#\n"
      io << "# Minimal, self-contained example of a single " << w.klass << " widget.\n"
      io << "# Run it:        crystal run " << relative_to_root(example_paths(w, total)[index]) << "\n"
      io << "# Screenshot it: regenerated by tools/widget-examples.cr\n"
      io << "require \"" << req << "\"\n\n"
      io << "Crysterm::WidgetExample.run " << title.inspect << " do |screen|\n"
      css.try { |c| io << "  screen.stylesheet = " << c.inspect << "\n" }
      io << body << "\n"
      io << "end\n"
    end
  end

  # Strip the common leading indentation from *text* and re-indent every
  # non-blank line by *prefix*, so recipe bodies land at a consistent depth
  # regardless of how their heredoc happened to be indented.
  def self.reindent(text : String, prefix : String) : String
    lines = text.lines
    min = lines.reject(&.strip.empty?).map { |l| l.size - l.lstrip.size }.min? || 0
    lines.map { |l| l.strip.empty? ? "" : prefix + l[min..] }.join("\n")
  end

  def self.relative_to_root(path : String) : String
    path.starts_with?(ROOT) ? path[(ROOT.size + 1)..] : path
  end

  # ---- doc-comment maintenance ----------------------------------------------
  #
  # Each widget's API docs (via `crystal docs`) get its screenshot embedded by a
  # managed block inside the *class doc comment* of its source file. The block is
  # fenced by HTML comments (invisible in the rendered Markdown) so the tool can
  # find, refresh, or migrate it without disturbing hand-written prose:
  #
  #     # <!-- widget-examples:capture v1 -->
  #     # ![Button screenshot](../../examples/widget/button/button-capture.png)
  #     # <!-- /widget-examples:capture -->
  #
  # `crystal docs` emits the `src` verbatim, resolved relative to the class's
  # generated page (`docs/Crysterm/Widget/Button.html`). `--docs` copies the
  # whole `examples/widget/` tree to `docs/examples/widget/`, and the `../`
  # prefix (one per namespace level of the class) walks from the page back to the
  # docs root, so the reference resolves with no network and no per-page assets.

  # Bump when the block's rendered shape changes; lets `--doc-comments` recognize
  # and rewrite an older block. The migration matcher keys off the stable
  # `widget-examples:capture` token, so even the version label can change.
  DOC_VERSION = "v1"
  DOC_OPEN    = "<!-- widget-examples:capture #{DOC_VERSION} -->"
  DOC_CLOSE   = "<!-- /widget-examples:capture -->"

  # Migration-safe fence detection (matches any past/version of the block).
  DOC_OPEN_RE  = /<!--\s*widget-examples:capture\b[^>]*-->/
  DOC_CLOSE_RE = /<!--\s*\/\s*widget-examples:capture\b[^>]*-->/

  # Existing screenshots for a widget, as bare filenames.
  def self.capture_filenames(w : Item) : Array(String)
    recipes_for(w).size.times.compact_map do |i|
      png = screenshot_path(w, i)
      File.exists?(png) ? File.basename(png) : nil
    end.to_a
  end

  # How many `../` it takes to get from *w*'s generated page directory back to
  # the docs root — one per namespace level (Crysterm::Widget::Button -> 2).
  def self.doc_depth(w : Item) : Int32
    w.fqn.split("::").size - 1
  end

  # The image path written into the doc comment: from the class page, up to the
  # docs root, then into the copied `examples/<kind>/<rel>/` tree.
  def self.doc_image_ref(w : Item, filename : String) : String
    ("../" * doc_depth(w)) + "#{relative_to_root(example_dir(w))}/#{filename}"
  end

  # The managed block's lines (without trailing newline), at *indent*, or nil if
  # the widget has no screenshot to show yet.
  def self.doc_block_lines(w : Item, indent : String) : Array(String)?
    files = capture_filenames(w)
    return nil if files.empty?
    lines = ["#{indent}# #{DOC_OPEN}"]
    files.each_with_index do |file, i|
      alt = i == 0 ? "#{w.klass} screenshot" : "#{w.klass} screenshot #{i + 1}"
      lines << "#{indent}# ![#{alt}](#{doc_image_ref(w, file)})"
    end
    lines << "#{indent}# #{DOC_CLOSE}"
    lines
  end

  # Source lines that the screenshot block attaches to: the widget's `class`,
  # plus any *case-only* alias of it (e.g. `alias Checkbox = CheckBox`). The
  # alias matters because, on a case-insensitive filesystem, `crystal docs`
  # writes `Checkbox.html` and `CheckBox.html` to the same file and the alias
  # page (no doc comment) would otherwise clobber the class page's screenshot —
  # so we document the alias too. Each anchor is {line index, indentation}.
  def self.doc_anchors(lines : Array(String), klass : String) : Array({Int32, String})
    class_re = /^(\s*)class\s+#{Regex.escape(klass)}\b/
    alias_re = /^(\s*)alias\s+([A-Za-z0-9_]+)\s*=\s*#{Regex.escape(klass)}\b/
    anchors = [] of {Int32, String}
    lines.each_with_index do |line, i|
      if m = class_re.match(line)
        anchors << {i, m[1]}
      elsif m = alias_re.match(line)
        name = m[2]
        anchors << {i, m[1]} if name != klass && name.compare(klass, case_insensitive: true) == 0
      end
    end
    anchors
  end

  # Remove every managed block (and the blank-comment separator above it) from
  # *lines* in place. Returns whether anything was removed.
  def self.strip_managed_blocks(lines : Array(String)) : Bool
    removed = false
    while oi = lines.index { |l| l =~ DOC_OPEN_RE }
      rel_ci = lines[oi..].index { |l| l =~ DOC_CLOSE_RE }
      break unless rel_ci
      ci = oi + rel_ci
      start = (oi > 0 && lines[oi - 1] =~ /^\s*#\s*$/) ? oi - 1 : oi
      lines.delete_at(start..ci)
      removed = true
    end
    removed
  end

  # Insert or refresh the managed screenshot block above *w*'s class (and any
  # case-only alias). Returns :inserted, :updated, :unchanged, :no_capture or
  # :no_class.
  def self.maintain_doc_comment(w : Item) : Symbol
    original = File.read(w.src)
    lines = original.split('\n')

    had_block = strip_managed_blocks(lines)
    anchors = doc_anchors(lines, w.klass)
    return :no_class if anchors.empty?

    if capture_filenames(w).empty?
      # No screenshot yet: leave the file as-is apart from removing a stale block.
      return write_if_changed(w.src, original, lines) ? :updated : :no_capture
    end

    # Insert above each anchor, bottom-most first so earlier indices stay valid.
    # A blank-comment line separates the image from any existing doc-comment
    # prose; with no prose the block becomes the anchor's doc comment.
    anchors.sort_by! { |(idx, _)| -idx }
    anchors.each do |(idx, indent)|
      insertion = [] of String
      insertion << "#{indent}#" if idx > 0 && lines[idx - 1] =~ /^\s*#/
      insertion.concat doc_block_lines(w, indent).not_nil!
      lines = lines[0...idx] + insertion + lines[idx..]
    end

    changed = write_if_changed(w.src, original, lines)
    changed ? (had_block ? :updated : :inserted) : :unchanged
  end

  def self.write_if_changed(path : String, original : String, lines : Array(String)) : Bool
    updated = lines.join('\n')
    return false if updated == original
    File.write(path, updated)
    true
  end

  # Maintain the managed screenshot block in every selected widget's source,
  # printing a one-line outcome per file.
  def self.maintain_doc_comments(widgets : Array(Item)) : Nil
    counts = Hash(Symbol, Int32).new(0)
    widgets.each do |w|
      result = maintain_doc_comment(w)
      counts[result] += 1
      verb = case result
             when :inserted   then "doc+   "
             when :updated    then "doc~   "
             when :unchanged  then "doc=   "
             when :no_capture then "doc?   "
             when :no_class   then "doc!   "
             else                  "doc    "
             end
      next if result == :unchanged
      note = result == :no_class ? " (no `class #{w.klass}` found)" : result == :no_capture ? " (no screenshot yet)" : ""
      puts "#{verb}#{relative_to_root(w.src)}#{note}"
    end
    puts
    puts "Doc comments: #{counts[:inserted]} inserted, #{counts[:updated]} updated, " \
         "#{counts[:unchanged]} unchanged, #{counts[:no_capture]} without a shot, " \
         "#{counts[:no_class]} unresolved."
  end

  # ---- docs build + asset copy ----------------------------------------------

  # Source trees (relative to the project root) copied verbatim into `docs/` so
  # the doc-comment image references resolve. `examples/widget/` carries the
  # screenshots; add more here if other docs reference in-repo assets.
  DOCS_ASSETS = ["examples/widget", "examples/layout"]

  # Run `crystal docs`, then mirror DOCS_ASSETS into the generated tree
  # (`examples/widget/` -> `docs/examples/widget/`).
  def self.build_docs : Nil
    puts "running `crystal docs` ..."
    status = Process.run("crystal", ["docs"], output: STDOUT, error: STDERR, chdir: ROOT)
    unless status.success?
      STDERR.puts "crystal docs failed (exit #{status.exit_code})"
      exit 1
    end
    DOCS_ASSETS.each do |rel|
      src = File.join(ROOT, rel)
      next unless Dir.exists?(src)
      dst = File.join(ROOT, "docs", rel)
      FileUtils.rm_rf(dst)
      FileUtils.mkdir_p(File.dirname(dst))
      FileUtils.cp_r(src, dst)
      puts "copied #{rel} -> docs/#{rel}"
    end
  end

  # ---- options --------------------------------------------------------------

  class Options
    property force = false
    property no_shot = false
    property shots_only = false
    property list = false
    property doc_comments = false
    property docs = false
    property jobs = WidgetExamples.default_jobs
    property filters = [] of String

    def matches?(w : Item) : Bool
      return true if filters.empty?
      filters.any? do |f|
        fl = f.downcase
        w.basename.downcase == fl || w.klass.downcase == fl || w.rel.downcase == fl
      end
    end
  end

  def self.parse_options(argv : Array(String)) : Options
    o = Options.new
    i = 0
    while i < argv.size
      arg = argv[i]
      case arg
      when "-f", "--force"  then o.force = true
      when "--no-shot"      then o.no_shot = true
      when "--shots-only"   then o.shots_only = true
      when "--list"         then o.list = true
      when "--doc-comments" then o.doc_comments = true
      when "--docs"         then o.docs = true
      when "-j", "--jobs"
        i += 1
        o.jobs = (i < argv.size ? argv[i].to_i? : nil) || o.jobs
        o.jobs = 1 if o.jobs < 1
      when "--only"
        i += 1
        o.filters << argv[i] if i < argv.size
      when "-h", "--help"
        puts HELP
        exit 0
      else
        if arg.starts_with?("-")
          STDERR.puts "unknown option: #{arg}"
          exit 2
        end
        o.filters << arg
      end
      i += 1
    end
    o
  end

  HELP = <<-TXT
    widget-examples.cr v#{VERSION} — generate + screenshot per-widget examples.

    Usage: crystal run tools/widget-examples.cr -- [options] [widget ...]

      -f, --force       overwrite existing example files
          --only NAME   restrict to NAME (repeatable; bare args work too)
          --no-shot     generate files but skip screenshots
          --shots-only  only (re)take screenshots; don't touch files
      -j, --jobs N      screenshot concurrency (default #{default_jobs}; each shot is a compile)
          --doc-comments insert/refresh each widget's screenshot in its source
                        class doc comment (so `crystal docs` shows it)
          --docs        run `crystal docs`, then copy examples/widget into docs/
          --list        show the plan and exit
      -h, --help        this help

    With no mode flag the default is: generate missing example files + screenshot.
    --doc-comments and --docs run only their own step (respecting [widget ...]).
    TXT

  # ---- screenshot -----------------------------------------------------------

  # Default screenshot concurrency. Each shot is a full `crystal` compile (RAM
  # heavy), so stay well under the core count; override with `--jobs`.
  def self.default_jobs : Int32
    Math.max(1, Math.min(4, System.cpu_count.to_i - 1))
  end

  # Run *work* over *items* with at most *jobs* fibers in flight. Each fiber's
  # `crystal run` subprocess runs in parallel via the OS while the fibers
  # themselves stay cooperative (single-threaded), so the shared counters *work*
  # touches need no locking.
  def self.parallel_each(items : Array(T), jobs : Int32, &work : T ->) forall T
    return if items.empty?
    queue = Channel(T).new(items.size)
    items.each { |i| queue.send i }
    queue.close
    done = Channel(Nil).new
    n = Math.min(jobs, items.size)
    n.times do
      spawn do
        while item = queue.receive?
          work.call item
        end
        done.send nil
      end
    end
    n.times { done.receive }
  end

  # Run an example headlessly and capture it to *png*. Returns {ok, message}.
  def self.screenshot(example_cr : String, png : String) : {Bool, String}
    io = IO::Memory.new
    status = Process.run(
      "crystal", ["run", "--no-color", example_cr],
      env: {"CRYSTERM_SHOT" => png},
      output: io, error: io, chdir: ROOT)
    if status.success? && File.exists?(png)
      {true, "#{relative_to_root(png)} (#{File.size(png)} bytes)"}
    else
      tail = io.to_s.lines.last(6).join("\n")
      {false, tail.empty? ? "exit #{status.exit_code}" : tail}
    end
  end

  # ---- main -----------------------------------------------------------------

  def self.run(argv : Array(String))
    opts = parse_options(argv)
    all = discover
    widgets = all.select { |w| opts.matches?(w) }

    if widgets.empty?
      STDERR.puts "no matching widgets (#{all.size} discovered)"
      exit 1
    end

    if opts.list
      puts "#{widgets.size} widget(s):"
      widgets.each do |w|
        recipe_kind = recipe?(w) ? "recipe" : "generic"
        puts "  %-22s %-32s [%s] -> %s" % [
          w.basename, w.fqn, recipe_kind, relative_to_root(example_dir(w)),
        ]
      end
      return
    end

    # Doc-comment maintenance and docs build are standalone steps.
    if opts.doc_comments
      maintain_doc_comments(widgets)
      return
    end
    if opts.docs
      build_docs
      return
    end

    generated = 0
    skipped = 0
    generics = [] of String
    # Examples to screenshot, collected in the (sequential) generation phase and
    # shot in parallel afterwards. Each is {widget, example.cr, target png}.
    to_shoot = [] of {Item, String, String}

    widgets.each do |w|
      generics << w.basename unless recipe?(w)
      recipes = recipes_for(w)
      paths = example_paths(w, recipes.size)
      FileUtils.mkdir_p(example_dir(w))

      paths.each_with_index do |path, idx|
        unless opts.shots_only
          if File.exists?(path) && !opts.force
            skipped += 1
            puts "skip   #{relative_to_root(path)} (exists; --force to overwrite)"
          else
            File.write(path, render_example(w, recipes[idx], idx, recipes.size))
            generated += 1
            puts "write  #{relative_to_root(path)}"
          end
        end

        next if opts.no_shot
        next unless File.exists?(path) # nothing to shoot (shots-only, missing file)
        to_shoot << {w, path, screenshot_path(w, idx)}
      end
    end

    shot_ok = 0
    shot_fail = 0
    failures = [] of String
    unless to_shoot.empty?
      puts "shooting #{to_shoot.size} example(s) with #{Math.min(opts.jobs, to_shoot.size)} job(s)..."
      parallel_each(to_shoot, opts.jobs) do |(w, path, png)|
        ok, msg = screenshot(path, png)
        if ok
          shot_ok += 1
          puts "shot   #{msg}"
        else
          shot_fail += 1
          failures << w.basename
          # One `puts` so a failure's lines can't interleave with another job's.
          puts(String.build do |io|
            io << "FAIL   " << relative_to_root(path)
            msg.each_line { |l| io << "\n         " << l }
          end)
        end
      end
    end

    puts
    puts "Summary: #{generated} written, #{skipped} skipped, " \
         "#{shot_ok} shots ok, #{shot_fail} shots failed."
    unless failures.empty?
      puts "Build/shot failures (need a working recipe): #{failures.uniq.join(", ")}"
    end
    unless generics.empty?
      puts "Using the generic template (groom into real recipes): #{generics.uniq.join(", ")}"
    end
  end
end

WidgetExamples.run(ARGV)
