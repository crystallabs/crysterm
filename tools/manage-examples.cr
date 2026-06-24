#!/usr/bin/env crystal
#
# manage-examples.cr — maintenance tool that standardizes how every Crysterm
# widget AND layout is exemplified, screenshotted and animated.
#
# For each widget under `src/widget/` and each layout under `src/layout/`, it:
#
#   1. Mirrors the source hierarchy into `examples/<kind>/` and gives the item
#      its own directory, e.g.
#          src/widget/button.cr    -> examples/widget/button/
#          src/widget/graph/bar.cr -> examples/widget/graph/bar/
#          src/layout/hbox.cr      -> examples/layout/hbox/
#   2. Writes one (or, rarely, several) *minimal* example(s) into that directory,
#      each named after the item (`button.cr`, or `button2.cr`, ...). Existing
#      files are left untouched unless `--force` is given.
#   3. Renders the example headlessly and saves a still beside it as
#      `<name>-capture.png`. With `--anim`, *every* example is instead recorded
#      as `<name>-capture<secs>s.apng`: ones with a demo `script` are driven
#      (synthetic key/mouse events), the rest are a static hold. Both go through
#      the shared harness in `examples/widget/example.cr` (CRYSTERM_SHOT /
#      CRYSTERM_ANIM).
#   4. `--build`/`--release` compile every example (a build-health check).
#   5. `--doc-comments` embeds each item's screenshot in its API docs by
#      maintaining a fenced block in the class doc comment; `--docs` runs
#      `crystal docs` and copies `examples/` into the docs tree.
#
# Groomed over time by adding/refining recipes (WIDGET_RECIPES / LAYOUT_RECIPES);
# a recipe's optional `script` is the per-item demo (a thin wrapper over input
# emits) replayed for the animation.
#
# Usage:
#   crystal run tools/manage-examples.cr -- [options] [name ...]
#
# Options:
#   -f, --force         Overwrite/recreate existing example files.
#       --only NAME     Restrict to NAME (repeatable; bare args work too).
#       --no-shot       Generate files but skip screenshots.
#       --shots-only    Only (re)capture; don't (re)generate files.
#       --anim          Record an APNG for every example (scripted ones play their demo).
#       --duration N    Animation length in seconds (default 5).
#       --build         Compile every example next to its source, x/<prog>.cr ->
#                       x/<prog> (build-health check).
#       --release       Like --build, but a crystal --release (optimized) build.
#   -j, --jobs N        Screenshot/anim/build concurrency (default ~cores-1).
#       --doc-comments  Insert/refresh the screenshot block in each source class
#                       doc comment (idempotent; migrates old blocks).
#       --docs          Run `crystal docs`, then copy examples/ into docs/.
#       --copy          Just copy examples/ into docs/ (skip `crystal docs`).
#       --list          List the discovered items and exit.
#   -h, --help          This help.
#
# Examples:
#   crystal run tools/manage-examples.cr --                 # fill in missing + shoot
#   crystal run tools/manage-examples.cr -- --list          # see the plan
#   crystal run tools/manage-examples.cr -- box hbox        # just these two
#   crystal run tools/manage-examples.cr -- --anim list     # record list's APNG
#   crystal run tools/manage-examples.cr -- --build         # compile every example
#   crystal run tools/manage-examples.cr -- --docs          # API docs with screenshots

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

  # A single example to emit for a widget: an optional CSS stylesheet, the body
  # that constructs the widget(s) inside the `WidgetExample.run` block, and an
  # optional `script` — a sequence of `Driver` calls (`d.key :down`, `d.type
  # "hi"`, ...) that drives the widget for the animated (APNG) capture. Widgets
  # with no script still get an APNG — a static hold. `%{fqn}` / `%{klass}` /
  # `%{name}` are interpolated in all three.
  record Recipe, css : String?, body : String, script : String? = nil

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
      body: <<-CR,
        bar = %{fqn}.new parent: screen, top: "center", left: "center", width: 40, height: 3
        bar.value = 65
      CR
      script: <<-CR
        d.hold 0.5
        # Ramp the value up and back to its initial 65 (read-only widget, no keys —
        # reach it via the screen and set #value, guarded by the concrete type).
        [65, 75, 85, 95, 85, 75, 65].each do |v|
          d.act(dwell: 0.4) { |s| s.children.each { |c| c.value = v if c.is_a?(%{fqn}) } }
        end
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
      body: <<-CR,
        list = %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 28, height: 9,
          items: %w[Alpha Beta Gamma Delta Epsilon]
        list.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :down, times: 4, dwell: 0.4
        d.key :up, times: 2, dwell: 0.4
        d.key :end, dwell: 0.6
        d.key :home, dwell: 0.6
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
      body: <<-CR,
        g = %{fqn}.new parent: screen, top: "center", left: "center", width: 40, height: 3
        g.value = 65
      CR
      script: <<-CR
        d.hold 0.5
        # Ramp the value up and back to its initial 65 (read-only widget, no keys —
        # reach it via the screen and set #value, guarded by the concrete type).
        [65, 75, 85, 95, 85, 75, 65].each do |v|
          d.act(dwell: 0.4) { |s| s.children.each { |c| c.value = v if c.is_a?(%{fqn}) } }
        end
      CR
    )],
    "GaugeList" => [Recipe.new(
      css: "GaugeList { border: solid; }",
      body: <<-CR,
        gl = %{fqn}.new parent: screen, top: "center", left: "center", width: 46, height: 9
        gl.add_gauge "CPU", 72
        gl.add_gauge "Memory", 48
        gl.add_gauge "Disk", 91
      CR
      script: <<-CR
        d.hold 0.5
        # Ramp the gauges and return to the initial set (reach the widget via the screen).
        [[72.0, 48.0, 91.0], [88.0, 64.0, 76.0], [96.0, 80.0, 62.0], [88.0, 64.0, 76.0], [72.0, 48.0, 91.0]].each do |vals|
          d.act(dwell: 0.45) { |s| s.children.each { |c| vals.each_with_index { |v, i| c[i] = v if i < c.gauges.size } if c.is_a?(%{fqn}) } }
        end
      CR
    )],
    "Checkbox" => [Recipe.new(
      css: "Checkbox { color: #c0caf5; }",
      body: <<-CR,
        cb = %{fqn}.new parent: screen, top: "center", left: "center", checked: true, content: "Enable feature"
        cb.focus
      CR
      script: <<-CR
        d.hold 0.6
        4.times { d.key :space, dwell: 0.8 }
      CR
    )],
    "RadioButton" => [Recipe.new(
      css: "RadioButton { color: #c0caf5; }",
      body: <<-CR,
        rb = %{fqn}.new parent: screen, top: "50%-1", left: "center", content: "Enable option"
        rb.focus
      CR
      script: <<-CR
        d.hold 0.6
        d.key :space, dwell: 0.9
        d.key :space, dwell: 0.9
      CR
    )],
    "Slider" => [Recipe.new(
      css: "Slider { color: #bb9af7; }",
      body: <<-CR,
        slider = %{fqn}.new parent: screen, top: "center", left: "center", width: 40, height: 1, value: 40
        slider.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :right, times: 5, dwell: 0.3
        d.key :left, times: 5, dwell: 0.3
      CR
    )],
    "SpinBox" => [Recipe.new(
      css: "SpinBox { border: solid; color: #c0caf5; }",
      body: <<-CR,
        sb = %{fqn}.new parent: screen, top: "center", left: "center", width: 14, height: 3, value: 42
        sb.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :up, times: 4, dwell: 0.35
        d.key :down, times: 4, dwell: 0.35
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
      body: <<-CR,
        cal = %{fqn}.new parent: screen, top: "center", left: "center", date: Time.utc(2026, 6, 24)
        cal.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :right, times: 3, dwell: 0.35
        d.key :down, times: 2, dwell: 0.4
        d.key :up, times: 2, dwell: 0.4
        d.key :left, times: 3, dwell: 0.35
      CR
    )],
    "Marquee" => [Recipe.new(
      css: "Marquee { color: #e0af68; }",
      body: <<-CR
        m = %{fqn}.new parent: screen, top: "center", left: "center", width: 40, height: 1, text: "Scrolling marquee text — Crysterm * "
        Crysterm::WidgetExample.animate_with(m.interval) { m.step }
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
      css: "SplashScreen { border: solid; background-color: #11121a; color: #c0caf5; }",
      body: <<-CR
        # `content` is the central widget shown on the splash (not a string).
        splash = %{fqn}.new parent: screen, width: 50, height: 15, message_height: 1,
          content: Crysterm::Widget::Box.new(
            top: "center", left: "center", width: 44, height: 8, parse_tags: true,
            content: "{center}{bold}C R Y S T E R M{/bold}\\n\\nTerminal UI toolkit for Crystal\\n\\nv1.0.0  •  90+ widgets  •  layouts  •  effects{/center}")
        splash.show_message "Loading modules…"
      CR
    )],
    "Pine::MessageView" => [Recipe.new(
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
        # compact: spinner is inline with the text ("⠋ Loading…") on one row.
        l = %{fqn}.new parent: screen, top: "center", left: "center", width: 30, height: 1,
          compact: true, content: "Loading…"
        Crysterm::WidgetExample.animate_with(l.interval) { l.step }
      CR
    )],
    # Self-animating effects: register the per-tick advance with the harness
    # (`animate_with`) instead of calling `start`, so the harness stays the single
    # frame source and the recorded APNG plays back at the effect's real speed
    # (a widget that rendered on its own fiber would inflate the frame count and
    # play slow). The harness drives it live/headless/pre-rolled per mode.
    "Effect::Matrix" => [Recipe.new(
      css: nil,
      body: <<-CR
        rain = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
        Crysterm::WidgetExample.animate_with(rain.interval) { rain.step }
      CR
    )],
    "Effect::Spray" => [Recipe.new(
      css: nil,
      body: <<-CR
        fx = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
        Crysterm::WidgetExample.animate_with(fx.interval) { fx.step }
      CR
    )],
    "Effect::Fire" => [Recipe.new(
      css: nil,
      body: <<-CR
        fx = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
        Crysterm::WidgetExample.animate_with(fx.interval) { fx.step }
      CR
    )],
    "Effect::Plasma" => [Recipe.new(
      css: nil,
      body: <<-CR
        fx = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
        Crysterm::WidgetExample.animate_with(fx.interval) { fx.step }
      CR
    )],
    # One CopperBar is a single flat row; the classic Amiga effect is a stack of
    # glossy "tubes". Build each tube from thin rows whose brightness ramps from
    # dark edges to a bright centre — a smooth TrueColor vertical gradient — and
    # stack several at different hues, all cycling together.
    "Effect::CopperBar" => [Recipe.new(
      css: nil,
      body: <<-CR
        hues = [0, 70, 150, 230]
        bar_h = 4
        bars = [] of %{fqn}
        hues.each_with_index do |hue, b|
          bar_h.times do |r|
            edge = (r * 2 - (bar_h - 1)).abs / (bar_h - 1).to_f # 0 centre .. 1 edge
            bars << %{fqn}.new \\
              parent: screen, left: 0, width: "100%", height: 1,
              top: 2 + b * (bar_h + 1) + r, hue_offset: hue, brightness: 1.0 - 0.75 * edge
          end
        end
        Crysterm::WidgetExample.animate_with(bars.first.interval) { bars.each(&.step) }
      CR
    )],
    "Effect::SineScroller" => [Recipe.new(
      css: nil,
      body: <<-CR
        fx = %{fqn}.new parent: screen, top: "center", left: 0, width: "100%", height: 11,
          text: "CRYSTERM * SINE SCROLLER * "
        Crysterm::WidgetExample.animate_with(fx.interval) { fx.step }
      CR
    )],
    # LineChart (and Canvas/sparklines) plot in Braille on a sub-cell canvas.
    "Graph::LineChart" => [Recipe.new(
      css: "LineChart { border: solid; color: #c0caf5; }",
      body: <<-CR
        chart = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%", height: "100%", title: "Signals"
        chart.add_line "sin", (0..160).map { |i| {i / 20.0, Math.sin(i / 20.0)} }
        chart.add_line "cos", (0..160).map { |i| {i / 20.0, Math.cos(i / 20.0) * 0.6} }
      CR
    )],
    "TextBox" => [Recipe.new(
      css: "TextBox { border: solid; color: #c0caf5; background-color: #1f2335; }",
      body: <<-CR,
        tb = %{fqn}.new parent: screen, top: "center", left: "center", width: 42, height: 3
        tb.value = "Editable text — type here"
        tb.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.type " more", dwell: 0.16
        d.key :backspace, times: 5, dwell: 0.16
      CR
    )],
    "TextArea" => [Recipe.new(
      css: "TextArea { border: solid; color: #c0caf5; background-color: #1f2335; }",
      body: <<-CR,
        ta = %{fqn}.new parent: screen, top: "center", left: "center", width: 46, height: 9
        ta.value = "A multi-line text area.\\nLine two.\\nLine three.\\n\\nEdit freely."
        ta.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.type " edited", dwell: 0.14
        d.key :backspace, times: 7, dwell: 0.14
      CR
    )],
    "Tree" => [Recipe.new(
      css: "Tree { border: solid; color: #c0caf5; }",
      body: <<-CR,
        tree = %{fqn}.new parent: screen, top: "center", left: "center", width: 34, height: 12, label: " Project "
        src = tree.add "src"
        src.add "crysterm.cr"
        src.add "widget.cr"
        docs = tree.add "docs"
        docs.add "README.md"
        docs.add "USAGE.md"
        tree.add "shard.yml"
        tree.expand_all
        tree.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :down, times: 4, dwell: 0.35
        d.key :up, times: 4, dwell: 0.35
      CR
    )],
    "Table" => [Recipe.new(
      css: "Table { border: solid; color: #c0caf5; }",
      body: <<-CR,
        %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 48, height: 10,
          rows: [["Name", "Role", "Commits"], ["Ada", "Engineer", "128"], ["Linus", "Maintainer", "942"], ["Grace", "Architect", "377"]]
      CR
      script: <<-CR
        d.hold 0.5
        d.key :down, times: 3, dwell: 0.4
        d.key :up, times: 3, dwell: 0.4
      CR
    )],
    "ListTable" => [Recipe.new(
      css: "ListTable { border: solid; color: #c0caf5; }",
      body: <<-CR,
        lt = %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 48, height: 10,
          rows: [["File", "Size", "Modified"], ["crysterm.cr", "2.1K", "Jun 24"], ["widget.cr", "8.4K", "Jun 23"], ["shard.yml", "1.0K", "Jun 24"]]
        lt.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :down, times: 3, dwell: 0.4
        d.key :up, times: 3, dwell: 0.4
      CR
    )],
    "ListBar" => [Recipe.new(
      css: "ListBar { color: #c0caf5; }",
      body: <<-CR,
        lb = %{fqn}.new parent: screen, top: "center", left: 0, width: "100%", height: 1, keys: true, mouse: true
        lb.set_items(["File", "Edit", "View", "Tools", "Help"])
        lb.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :right, times: 4, dwell: 0.35
        d.key :left, times: 4, dwell: 0.35
      CR
    )],
    "ComboBox" => [Recipe.new(
      css: "ComboBox { border: solid; color: #c0caf5; }",
      body: <<-CR,
        %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 24, height: 3,
          options: %w[Red Green Blue Yellow], selected: 2
      CR
      script: <<-CR
        d.hold 0.5
        d.key :enter, dwell: 0.5
        d.key :down, dwell: 0.4
        d.key :up, dwell: 0.4
        d.key :escape, dwell: 0.5
      CR
    )],
    "RadioSet" => [Recipe.new(
      css: "RadioSet { border: solid; } RadioButton { color: #c0caf5; }",
      body: <<-CR,
        rs = %{fqn}.new parent: screen, top: "center", left: "center", width: 28, height: 7, label: " Size "
        btns = %w[Small Medium Large].map_with_index do |t, i|
          Crysterm::Widget::RadioButton.new parent: rs, top: i, left: 1, content: t, checked: i == 1
        end
        btns.first.focus
      CR
      # Walk the group selecting each option in turn — the set keeps the choice
      # exclusive — then step back to the initial "Medium" so the loop is seamless.
      script: <<-CR
        d.hold 0.4
        d.key :space, dwell: 0.5            # check Small (focused)
        d.key :tab; d.key :space, dwell: 0.5 # → Medium
        d.key :tab; d.key :space, dwell: 0.5 # → Large
        d.key :backtab; d.key :space, dwell: 0.6 # back to Medium (initial)
      CR
    )],
    "GroupBox" => [Recipe.new(
      css: "GroupBox { border: solid; color: #c0caf5; }",
      body: <<-CR
        gb = %{fqn}.new parent: screen, top: "center", left: "center", width: 40, height: 8, title: " Connection "
        Crysterm::Widget::Box.new parent: gb, top: 1, left: 2, content: "Host: localhost"
        Crysterm::Widget::Box.new parent: gb, top: 2, left: 2, content: "Port: 5432"
        Crysterm::Widget::Box.new parent: gb, top: 3, left: 2, content: "SSL:  enabled"
      CR
    )],
    "ScrollableBox" => [Recipe.new(
      css: "ScrollableBox { border: solid; color: #c0caf5; }",
      body: <<-CR,
        sb = %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 40, height: 9, scrollbar: true, keys: true,
          content: (1..30).map { |i| "Scrollable line \#{i}" }.join("\\n")
        sb.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :down, times: 8, dwell: 0.22
        d.key :up, times: 8, dwell: 0.22
      CR
    )],
    "ScrollableText" => [Recipe.new(
      css: "ScrollableText { border: solid; color: #c0caf5; }",
      body: <<-CR,
        st = %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 44, height: 9, scrollbar: true, keys: true,
          content: (1..40).map { |i| "Scrollable text line \#{i}" }.join("\\n")
        st.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :down, times: 8, dwell: 0.22
        d.key :up, times: 8, dwell: 0.22
      CR
    )],
    "Markdown" => [Recipe.new(
      css: "Markdown { border: solid; }",
      body: <<-CR
        md = %{fqn}.new parent: screen, top: "center", left: "center", width: 52, height: 14
        md.set_markdown "# Crysterm\\n\\nA **terminal UI** toolkit in *Crystal*.\\n\\n- Widgets\\n- Layouts\\n- Animations\\n\\n`crystal run examples/hello.cr`"
      CR
    )],
    "Gradient" => [Recipe.new(
      css: nil,
      body: <<-CR
        grad = %{fqn}.new \\
          parent: screen, top: 0, left: 0, width: "100%", height: "100%",
          colors: ["#ff0000", "#ffff00", "#00ff00", "#00ffff", "#0000ff", "#ff00ff"], direction: :horizontal
        Crysterm::WidgetExample.animate_with(0.08.seconds) { grad.phase += 0.06 }
      CR
    )],
    "Dial" => [Recipe.new(
      css: "Dial { border: solid; color: #7aa2f7; }",
      body: <<-CR,
        dial = %{fqn}.new parent: screen, top: "center", left: "center", width: 21, height: 11, value: 65
        dial.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :up, times: 4, dwell: 0.35
        d.key :down, times: 4, dwell: 0.35
      CR
    )],
    "DoubleSpinBox" => [Recipe.new(
      css: "DoubleSpinBox { border: solid; color: #c0caf5; }",
      body: <<-CR,
        %{fqn}.new parent: screen, top: "center", left: "center", width: 18, height: 3, value: 3.14, suffix: " kg"
      CR
      script: <<-CR
        d.hold 0.5
        d.key :up, times: 4, dwell: 0.35
        d.key :down, times: 4, dwell: 0.35
      CR
    )],
    "TabWidget" => [Recipe.new(
      css: "TabWidget { color: #c0caf5; }",
      body: <<-CR,
        tw = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
        tw.add_tab "Overview", Crysterm::Widget::Box.new(content: "{center}Overview page{/center}", parse_tags: true)
        tw.add_tab "Details", Crysterm::Widget::Box.new(content: "{center}Details page{/center}", parse_tags: true)
        tw.add_tab "Settings", Crysterm::Widget::Box.new(content: "{center}Settings page{/center}", parse_tags: true)
      CR
      script: <<-CR
        d.hold 0.5
        d.click 16, 0, dwell: 0.7
        d.click 28, 0, dwell: 0.7
        d.click 5, 0, dwell: 0.7
      CR
    )],
    "MenuBar" => [Recipe.new(
      css: "MenuBar { color: #c0caf5; } Menu { color: #c0caf5; }",
      body: <<-CR,
        mb = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%"
        file = mb.add_menu "File"
        %w[New Open Save Quit].each { |t| file.add t }
        %w[Edit View Tools Help].each { |t| mb.add_menu t }
      CR
      script: <<-CR
        d.hold 0.6
        # Open the File menu, then close it again.
        d.act(dwell: 1.2) { |s| s.children.each { |c| c.toggle(0) if c.is_a?(%{fqn}) } }
        d.act(dwell: 0.8) { |s| s.children.each { |c| c.toggle(0) if c.is_a?(%{fqn}) } }
      CR
    )],
    "Menu" => [Recipe.new(
      css: "Menu { border: solid; color: #c0caf5; }",
      body: <<-CR,
        menu = %{fqn}.new parent: screen, top: "center", left: "center"
        %w[New Open Save Quit].each { |t| menu.add t }
      CR
      script: <<-CR
        d.hold 0.5
        d.key :down, times: 3, dwell: 0.4
        d.key :up, times: 3, dwell: 0.4
      CR
    )],
    "Form" => [Recipe.new(
      css: "Form { border: solid; color: #c0caf5; } TextBox { background-color: #1f2335; }",
      body: <<-CR,
        form = %{fqn}.new parent: screen, top: "center", left: "center", width: 42, height: 10, label: " Sign in "
        Crysterm::Widget::Box.new parent: form, top: 1, left: 2, content: "User:"
        u = Crysterm::Widget::TextBox.new parent: form, top: 1, left: 9, width: 26, height: 1
        u.value = "ada"
        Crysterm::Widget::Box.new parent: form, top: 3, left: 2, content: "Pass:"
        p = Crysterm::Widget::TextBox.new parent: form, top: 3, left: 9, width: 26, height: 1, secret: true
        p.value = "secret"
      CR
      script: <<-CR
        d.hold 0.5
        d.key :tab, times: 2, dwell: 0.5
        d.key :backtab, times: 2, dwell: 0.5
      CR
    )],
    "Graph::Bar" => [Recipe.new(
      css: "Bar { border: solid; color: #7aa2f7; }",
      body: <<-CR
        %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 44, height: 12,
          values: [3.0, 7.0, 4.0, 9.0, 6.0, 8.0, 2.0, 5.0], labels: %w[Mon Tue Wed Thu Fri Sat Sun Avg],
          bar_width: 3, bar_spacing: 2, show_values: true
      CR
    )],
    "Graph::StackedBar" => [Recipe.new(
      css: "StackedBar { border: solid; color: #c0caf5; }",
      body: <<-CR,
        %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 46, height: 12,
          values: [[3.0, 2.0, 1.0], [2.0, 4.0, 2.0], [1.0, 3.0, 4.0], [4.0, 1.0, 2.0]],
          labels: %w[Q1 Q2 Q3 Q4], bar_width: 4, bar_spacing: 3
      CR
      script: <<-CR
        d.hold 0.5
        # Distinct proportions per frame (uniform scaling would leave the
        # auto-scaled chart unchanged); returns to the initial set.
        [
          [[3.0, 2.0, 1.0], [2.0, 4.0, 2.0], [1.0, 3.0, 4.0], [4.0, 1.0, 2.0]],
          [[5.0, 1.0, 2.0], [1.0, 2.0, 5.0], [3.0, 3.0, 2.0], [2.0, 5.0, 1.0]],
          [[1.0, 4.0, 4.0], [5.0, 1.0, 1.0], [2.0, 2.0, 5.0], [4.0, 4.0, 1.0]],
          [[3.0, 2.0, 1.0], [2.0, 4.0, 2.0], [1.0, 3.0, 4.0], [4.0, 1.0, 2.0]],
        ].each do |vals|
          d.act(dwell: 0.6) { |s| s.children.each { |c| c.values = vals if c.is_a?(%{fqn}) } }
        end
      CR
    )],
    "Graph::Donut" => [Recipe.new(
      css: nil,
      body: <<-CR,
        # No show_track: the braille backend is one colour per cell, so a track
        # ring's dim "off" dots can't be distinguished and just clutter the arc.
        %{fqn}.new parent: screen, top: "center", left: "center", width: 24, height: 12, value: 65
      CR
      script: <<-CR
        d.hold 0.5
        # Ramp the value up and back to its initial 65 (read-only widget, no keys —
        # reach it via the screen and set #value, guarded by the concrete type).
        [65, 75, 85, 95, 85, 75, 65].each do |v|
          d.act(dwell: 0.4) { |s| s.children.each { |c| c.value = v if c.is_a?(%{fqn}) } }
        end
      CR
    )],
    "Graph::Map" => [Recipe.new(
      css: "Map { border: solid; }",
      body: <<-CR
        map = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
        map.add_marker 40.7, -74.0, '*', 0xE05050, "NYC"
        map.add_marker 51.5, -0.12, '*', 0x40E0D0, "London"
        map.add_marker 35.7, 139.7, '*', 0xE0A040, "Tokyo"
        map.add_marker(-33.9, 151.2, '*', 0x60C040, "Sydney")
      CR
    )],
    "DateEdit" => [Recipe.new(
      css: "DateEdit { border: solid; color: #c0caf5; }",
      body: <<-CR,
        de = %{fqn}.new parent: screen, top: "center", left: "center", width: 16, height: 3, date: Time.utc(2026, 6, 24)
        de.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :enter, dwell: 0.6
        d.key :right, times: 3, dwell: 0.35
        d.key :down, dwell: 0.4
        d.key :escape, dwell: 0.6
      CR
    )],
    "TimeEdit" => [Recipe.new(
      css: "TimeEdit { border: solid; color: #c0caf5; }",
      body: <<-CR,
        te = %{fqn}.new parent: screen, top: "center", left: "center", width: 14, height: 3, time: Time.utc(2026, 6, 24, 13, 37, 5)
        te.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :up, times: 3, dwell: 0.4
        d.key :down, times: 3, dwell: 0.4
      CR
    )],
    "DateTimeEdit" => [Recipe.new(
      css: "DateTimeEdit { border: solid; color: #c0caf5; }",
      body: <<-CR,
        dte = %{fqn}.new parent: screen, top: "center", left: "center", width: 26, height: 3, date_time: Time.utc(2026, 6, 24, 13, 37, 5)
        dte.focus
      CR
      script: <<-CR
        d.hold 0.5
        d.key :up, times: 3, dwell: 0.4
        d.key :down, times: 3, dwell: 0.4
      CR
    )],
    "Line" => [Recipe.new(
      css: "Line { color: #7aa2f7; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "center", left: 4, width: 40, orientation: :horizontal
      CR
    )],
    # Like Qt's QSplitter, the panes aren't individually bordered — the draggable
    # divider (the `.divider` handle) is the separator between them.
    "Splitter" => [Recipe.new(
      css: "Splitter { border: solid; } .divider { background-color: #7aa2f7; } Box { color: #c0caf5; }",
      body: <<-CR
        sp = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%", height: "100%", orientation: :horizontal
        sp.add_pane Crysterm::Widget::Box.new(content: "{center}Left pane{/center}", parse_tags: true)
        sp.add_pane Crysterm::Widget::Box.new(content: "{center}Right pane{/center}", parse_tags: true)
      CR
    )],
    "StackedWidget" => [Recipe.new(
      css: "Box { border: solid; color: #c0caf5; }",
      body: <<-CR
        sw = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
        sw.add_page Crysterm::Widget::Box.new(content: "{center}Page 1 of 3\\n\\n(StackedWidget shows one page){/center}", parse_tags: true)
        sw.add_page Crysterm::Widget::Box.new(content: "{center}Page 2{/center}", parse_tags: true)
        sw.show_page 0
      CR
    )],
    "StatusBar" => [Recipe.new(
      css: "StatusBar { color: #c0caf5; background-color: #283457; }",
      body: <<-CR
        sb = %{fqn}.new parent: screen, bottom: 0, left: 0, width: "100%", height: 1
        sb.show_message "Ready"
        sb.add_permanent "Ln 12, Col 4"
        sb.add_permanent "UTF-8"
      CR
    )],
    "ToolBar" => [Recipe.new(
      css: "ToolBar { color: #c0caf5; }",
      body: <<-CR
        tb = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%"
        %w[New Open Save Cut Copy Paste].each { |t| tb.add_button(t) { } }
      CR
    )],
    "ToolBox" => [Recipe.new(
      css: "ToolBox { border: solid; color: #c0caf5; }",
      body: <<-CR
        tbx = %{fqn}.new parent: screen, top: "center", left: "center", width: 36, height: 14
        tbx.add_item "General", Crysterm::Widget::Box.new(content: "Theme, language, startup")
        tbx.add_item "Editor", Crysterm::Widget::Box.new(content: "Tabs, wrap, font size")
        tbx.add_item "Advanced", Crysterm::Widget::Box.new(content: "Proxies, caches, flags")
      CR
    )],
    "Tooltip" => [Recipe.new(
      css: "Box { border: solid; color: #c0caf5; } Tooltip { border: solid; color: #1a1a2e; background-color: #e0af68; }",
      body: <<-CR
        Crysterm::Widget::Box.new parent: screen, top: 3, left: 4, width: 24, height: 3,
          content: "{center}Hover target{/center}", parse_tags: true
        # The tooltip pops up just below the hovered target.
        tt = %{fqn}.new parent: screen
        tt.show_at 6, 6, "A helpful tooltip"
      CR
    )],
    "SizeGrip" => [Recipe.new(
      css: "Box { border: solid; color: #c0caf5; } SizeGrip { color: #7aa2f7; }",
      body: <<-CR
        Crysterm::Widget::Box.new parent: screen, top: 2, left: 2, width: 40, height: 14,
          content: " A resizable panel — the grip sits in its corner."
        %{fqn}.new parent: screen, top: 15, left: 41
      CR
    )],
    "ScrollBar" => [Recipe.new(
      css: "Box { border: solid; color: #c0caf5; } ScrollBar { color: #7aa2f7; }",
      body: <<-CR
        Crysterm::Widget::Box.new parent: screen, top: 2, left: 2, width: 42, height: 16,
          content: (1..30).map { |i| " Content line \#{i}" }.join("\\n")
        # A vertical scrollbar is one column wide; the thumb sits at `value`.
        %{fqn}.new parent: screen, top: 2, left: 45, width: 1, height: 16, orientation: :vertical, value: 35
      CR
    )],
    "DialogButtonBox" => [Recipe.new(
      css: "Box { border: solid; color: #c0caf5; } Button { color: #c0caf5; }",
      body: <<-CR
        Crysterm::Widget::Box.new parent: screen, top: "center", left: "center", width: 46, height: 8,
          content: "{center}\\nSave changes before closing?{/center}", parse_tags: true
        %{fqn}.new \\
          parent: screen, top: "50%+2", left: "center", width: 40, height: 1,
          buttons: %{fqn}::StandardButton::Ok | %{fqn}::StandardButton::Cancel
      CR
    )],
    "Wizard" => [Recipe.new(
      css: "Wizard { color: #c0caf5; }",
      body: <<-CR
        wiz = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
        wiz.add_page Crysterm::Widget::Box.new(content: "{center}Welcome to the setup wizard.{/center}", parse_tags: true), "Welcome"
        wiz.add_page Crysterm::Widget::Box.new(content: "{center}Choose your options.{/center}", parse_tags: true), "Options"
        wiz.add_page Crysterm::Widget::Box.new(content: "{center}All done!{/center}", parse_tags: true), "Finish"
      CR
    )],
    "Fps" => [Recipe.new(
      css: "Fps { border: solid; color: #9ece6a; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "center", left: "center", width: 30, height: 5
      CR
    )],
    "Prompt" => [Recipe.new(
      css: "Prompt { border: solid; color: #c0caf5; }",
      body: <<-CR
        %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 46, height: 7,
          content: "What is your name?"
      CR
    )],
    "Question" => [Recipe.new(
      css: "Question { border: solid; color: #c0caf5; }",
      body: <<-CR
        %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 46, height: 7,
          content: "Delete this file? This cannot be undone."
      CR
    )],
    "Input" => [Recipe.new(
      css: "Input { border: solid; color: #c0caf5; background-color: #1f2335; }",
      body: <<-CR
        %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 38, height: 3,
          content: "An Input — the base of the text widgets"
      CR
    )],
    "ToolButton" => [Recipe.new(
      css: "ToolButton { border: solid; background-color: #394b70; color: #c0caf5; }",
      body: <<-CR
        %{fqn}.new parent: screen, top: "center", left: "center", width: 14, height: 3, content: " Format ▾"
      CR
    )],
    "FileManager" => [Recipe.new(
      css: "FileManager { border: solid; color: #c0caf5; }",
      body: <<-CR
        fm = %{fqn}.new \\
          parent: screen, top: "center", left: "center", width: 46, height: 16,
          cwd: "src/widget", label: " src/widget "
        fm.focus
      CR
    )],
    "DockWidget" => [Recipe.new(
      css: "DockWidget { border: solid; color: #c0caf5; }",
      body: <<-CR
        dock = %{fqn}.new \\
          parent: screen, top: 0, left: 0, width: 26, height: "100%",
          title: " Explorer ", area: :left
        Crysterm::Widget::Box.new parent: dock, top: 0, left: 1, content: "src/"
        Crysterm::Widget::Box.new parent: dock, top: 1, left: 2, content: "crysterm.cr"
        Crysterm::Widget::Box.new parent: dock, top: 2, left: 2, content: "widget.cr"
      CR
    )],
    "MainWindow" => [Recipe.new(
      css: "Box { color: #c0caf5; } MenuBar { background-color: #283457; } StatusBar { background-color: #283457; }",
      body: <<-CR
        mw = %{fqn}.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
        mw.menu_bar = (mb = Crysterm::Widget::MenuBar.new)
        %w[File Edit View Help].each { |t| mb.add_menu t }
        dock = Crysterm::Widget::DockWidget.new title: " Project ", area: :left, dock_size: 22
        Crysterm::Widget::Box.new parent: dock, top: 0, left: 1, content: "src/\\n  crysterm.cr\\n  widget.cr\\ndocs/\\n  README.md"
        mw.add_dock dock
        mw.central_widget = Crysterm::Widget::Box.new(
          content: "{center}Editor — central widget{/center}", parse_tags: true,
          style: Crysterm::Style.new(border: true))
        mw.status_bar = (sb = Crysterm::Widget::StatusBar.new)
        sb.show_message "Ready"
        sb.add_permanent "Ln 1, Col 1"
      CR
    )],
    "Message" => [Recipe.new(
      css: "Message { border: solid; color: #c0caf5; background-color: #283457; }",
      body: <<-CR
        msg = %{fqn}.new parent: screen, top: "center", left: "center", width: 40, height: 7
        msg.display("File saved successfully.", 999.seconds) { }
      CR
    )],
    "Pine::HeaderBar" => [Recipe.new(
      css: "Pine::HeaderBar { color: #1a1a2e; background-color: #7aa2f7; }",
      body: <<-CR
        %{fqn}.new \\
          parent: screen, top: 0, left: 0,
          title_content: "PINE 4.0", section_content: "MESSAGE INDEX",
          info_content: "Folder: INBOX  12 Messages"
      CR
    )],
    "Pine::KeyMenu" => [Recipe.new(
      css: "Pine::KeyMenu { color: #c0caf5; }",
      body: <<-CR
        km = %{fqn}.new parent: screen, bottom: 0, left: 0, width: "100%", height: 2
        km.set_entries([
          %{fqn}::Entry.new("?", "Help"), %{fqn}::Entry.new("C", "Compose"),
          %{fqn}::Entry.new("D", "Delete"), %{fqn}::Entry.new("R", "Reply"),
          %{fqn}::Entry.new("Q", "Quit"),
        ])
      CR
    )],
    "Pine::FolderList" => [Recipe.new(
      css: "Pine::FolderList { border: solid; color: #c0caf5; }",
      body: <<-CR
        fl = %{fqn}.new parent: screen, top: "center", left: "center", width: 34, height: 12, label: " Folders "
        fl.set_folders([
          %{fqn}::Folder.new("INBOX", 12), %{fqn}::Folder.new("Sent", 48),
          %{fqn}::Folder.new("Drafts", 2), %{fqn}::Folder.new("Trash", 7),
        ])
        fl.focus
      CR
    )],
    "Pine::AddressBook" => [Recipe.new(
      css: "Pine::AddressBook { border: solid; color: #c0caf5; }",
      body: <<-CR
        ab = %{fqn}.new parent: screen, top: "center", left: "center", width: 50, height: 12, label: " Address Book "
        ab.set_contacts([
          %{fqn}::Contact.new("ada", "Ada Lovelace", "ada@example.com"),
          %{fqn}::Contact.new("linus", "Linus Torvalds", "linus@example.org"),
          %{fqn}::Contact.new("grace", "Grace Hopper", "grace@example.net"),
        ])
        ab.focus
      CR
    )],
    "Pine::MainMenu" => [Recipe.new(
      css: "Pine::MainMenu { border: solid; color: #c0caf5; }",
      body: <<-CR
        mm = %{fqn}.new parent: screen, top: "center", left: "center", width: 52, height: 12, label: " Main Menu "
        mm.set_options([
          %{fqn}::Option.new("C", "Compose", "Compose and send a message"),
          %{fqn}::Option.new("I", "Message Index", "View messages in the current folder"),
          %{fqn}::Option.new("L", "Folder List", "Select a folder to view"),
          %{fqn}::Option.new("A", "Address Book", "Update your address book"),
        ])
        mm.focus
      CR
    )],
    "Pine::MessageIndex" => [Recipe.new(
      css: "Pine::MessageIndex { border: solid; color: #c0caf5; }",
      body: <<-CR
        mi = %{fqn}.new parent: screen, top: "center", left: "center", width: 56, height: 12, label: " INBOX "
        mi.set_messages([
          %{fqn}::Message.new("Ada Lovelace", "Re: Analytical Engine", date: "Jun 24", unread: true),
          %{fqn}::Message.new("Grace Hopper", "Compiler patches", date: "Jun 23"),
          %{fqn}::Message.new("Linus T.", "Merge window", date: "Jun 22"),
        ])
        mi.focus
      CR
    )],
    "Pine::Setup" => [Recipe.new(
      css: "Pine::Setup { border: solid; color: #c0caf5; }",
      body: <<-CR
        st = %{fqn}.new parent: screen, top: "center", left: "center", width: 50, height: 12, label: " Setup "
        st.set_options([
          %{fqn}::Option.new("Printer", "Configure printer support", enabled: true),
          %{fqn}::Option.new("Newmail", "Notify on new mail", enabled: true),
          %{fqn}::Option.new("Threading", "Group messages by thread", enabled: false),
        ])
        st.focus
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

  # An item's name relative to its kind's namespace, e.g. "Box", "Graph::Bar",
  # "Pine::StatusBar" — the recipe key. Using the namespaced form disambiguates
  # same-simple-name classes (Widget::StatusBar vs Widget::Pine::StatusBar).
  def self.relname(w : Item) : String
    prefix = "#{w.kind.base_ns}::"
    w.fqn.starts_with?(prefix) ? w.fqn[prefix.size..] : w.fqn
  end

  # Case-insensitive recipe lookup keyed by `relname` (a file may declare
  # `CheckBox` while the key is `Checkbox` — Crysterm aliases some by case).
  def self.lookup_recipes(w : Item) : Array(Recipe)?
    rel = relname(w)
    recipe_map(w).each { |k, v| return v if k.compare(rel, case_insensitive: true) == 0 }
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

  # Where the *index*'th example's still screenshot goes: `<prog>-capture.png`,
  # `<prog>-capture2.png`, ... in the item's directory (`<prog>` is the widget
  # name; the number tracks the program index, empty for the first).
  def self.screenshot_path(w : Item, index : Int32) : String
    File.join(example_dir(w), "#{w.basename}-capture#{suffix(index)}.png")
  end

  # Where the *index*'th example's animation goes: `<prog>-capture<secs>s.apng`,
  # e.g. `list-capture5s.apng` (`<secs>` is the recording duration).
  def self.anim_path(w : Item, index : Int32, duration : Int32) : String
    File.join(example_dir(w), "#{w.basename}#{suffix(index)}-capture#{duration}s.apng")
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
    script = recipe.script.try { |s| reindent(interp.call(s).rstrip, "    ") }

    String.build do |io|
      label = total > 1 ? " (example #{index + 1} of #{total})" : ""
      io << "# Example: " << w.fqn << label << "\n"
      io << "#\n"
      io << "# Minimal, self-contained example of a single " << w.klass << ".\n"
      io << "# Run it:     crystal run " << relative_to_root(example_paths(w, total)[index]) << "\n"
      io << "# Maintained by tools/manage-examples.cr\n"
      io << "require \"" << req << "\"\n\n"
      if script
        # Animated demo: the `script` drives the widget (a thin wrapper over the
        # same event emits real input uses) when recording the APNG.
        io << "Crysterm::WidgetExample.run(" << title.inspect << ",\n"
        io << "  script: ->(d : Crysterm::WidgetExample::Driver) {\n"
        io << script << "\n"
        io << "  }) do |screen|\n"
      else
        io << "Crysterm::WidgetExample.run " << title.inspect << " do |screen|\n"
      end
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

  # The image each example contributes to the docs, as a bare filename. Prefers
  # the animation (`<prog>-capture<secs>s.apng`, which browsers play inline) and
  # falls back to the still (`<prog>-capture.png`) when there is no APNG.
  def self.capture_filenames(w : Item) : Array(String)
    recipes_for(w).size.times.compact_map do |i|
      apng = Dir.glob(File.join(example_dir(w), "#{w.basename}#{suffix(i)}-capture*s.apng")).sort.first?
      next File.basename(apng) if apng
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

  # Run `crystal docs`, then mirror DOCS_ASSETS into the generated tree.
  def self.build_docs : Nil
    puts "running `crystal docs` ..."
    status = Process.run("crystal", ["docs"], output: STDOUT, error: STDERR, chdir: ROOT)
    unless status.success?
      STDERR.puts "crystal docs failed (exit #{status.exit_code})"
      exit 1
    end
    copy_docs_assets
  end

  # Mirror DOCS_ASSETS into the (already-built) docs tree
  # (`examples/widget/` -> `docs/examples/widget/`), without re-running
  # `crystal docs`. Use after re-recording captures to refresh just the assets.
  def self.copy_docs_assets : Nil
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
    property copy = false
    property anim = false
    property duration = 5
    property build = false
    property release = false
    property jobs = WidgetExamples.default_jobs
    property filters = [] of String

    def matches?(w : Item) : Bool
      return true if filters.empty?
      filters.any? do |f|
        fl = f.downcase
        w.basename.downcase == fl || w.klass.downcase == fl || w.rel.downcase == fl
      end
    end

    # True when no step/mode flag is given (only the non-mode `--jobs`,
    # `--duration` and name filters may be present). `--force` then re-does the
    # whole chain (`#full_chain?`); without it, the bare run just fills in what's
    # missing and refreshes the docs (`#default_run?`).
    private def bare? : Bool
      !no_shot && !shots_only && !anim && !build && !doc_comments && !docs && !copy && !list
    end

    # `--force` on its own (no step/mode flag) means "re-do the whole chain":
    # generate, shoot stills, record APNGs, refresh doc-comments, build docs.
    # `--jobs`, `--duration` and name filters aren't mode flags, so they may
    # accompany it.
    def full_chain? : Bool
      force && bare?
    end

    # A bare run (no flags at all): generate only the *missing* example files and
    # stills, then run the docs output (`crystal docs` + asset copy). The
    # incremental cousin of `#full_chain?`.
    def default_run? : Bool
      !force && bare?
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
      when "--copy"         then o.copy = true
      when "--anim"         then o.anim = true
      when "--build"        then o.build = true
      when "--release"      then o.release = true; o.build = true
      when "--duration"
        i += 1
        o.duration = (i < argv.size ? argv[i].to_i? : nil) || o.duration
        o.duration = 1 if o.duration < 1
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
    manage-examples.cr v#{VERSION} — generate, screenshot & animate per-widget/layout examples.

    Usage: crystal run tools/manage-examples.cr -- [options] [name ...]

      -f, --force       overwrite existing example files
          --only NAME   restrict to NAME (repeatable; bare args work too)
          --no-shot     generate files but skip screenshots
          --shots-only  only (re)take screenshots; don't touch files
          --anim                                example that has a demo script, instead of a still
          --duration N  animation length in seconds (default 5)
          --build       compile each example next to its source (x/<prog>.cr -> x/<prog>)
          --release     like --build, but a crystal --release (optimized) build
      -j, --jobs N      screenshot/anim concurrency (default #{default_jobs}; each is a compile)
          --doc-comments insert/refresh each example's screenshot in its source
                        class doc comment (so `crystal docs` shows it)
          --docs        run `crystal docs`, then copy examples/ into docs/
          --copy        just copy examples/ into docs/ (skip `crystal docs`)
          --list        show the plan and exit
      -h, --help        this help

    With NO flags: generate missing example files + stills, then build docs
    (`crystal docs` + copy examples into docs/).
    -f/--force on its OWN (no mode flag) re-does the whole chain end to end:
    (re)generate -> stills -> anims -> doc-comments -> docs. Pair --force with a
    mode flag to force just that step (e.g. `--force --anim`).
    --anim, --doc-comments and --docs run only their own step.
    [name ...], --jobs and --duration may accompany any of the above.
    TXT

  # ---- screenshot -----------------------------------------------------------

  # Default screenshot concurrency. Each shot is a full `crystal` compile (RAM
  # heavy), so stay under the core count; override with `--jobs`.
  def self.default_jobs : Int32
    Math.max(1, Math.min(8, System.cpu_count.to_i - 1))
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

  # Whether an output (still / anim / binary) already exists and so must be left
  # alone (no --force). Prints a skip line when it does.
  def self.skip_output?(dest : String, force : Bool) : Bool
    return false if force || !File.exists?(dest)
    puts "skip   #{relative_to_root(dest)} (exists; --force to overwrite)"
    true
  end

  # `--build` compiles each example next to its source: `x/<prog>.cr` -> `x/<prog>`.
  def self.build_path(w : Item, index : Int32) : String
    File.join(example_dir(w), "#{w.basename}#{suffix(index)}")
  end

  # Compile *example_cr* to *bin* (optionally `--release`). Returns {ok, msg}.
  def self.build_example(example_cr : String, bin : String, release : Bool) : {Bool, String}
    args = ["build", "--no-color", example_cr, "-o", bin]
    args << "--release" if release
    io = IO::Memory.new
    status = Process.run("crystal", args, output: io, error: io, chdir: ROOT)
    if status.success? && File.exists?(bin)
      {true, "#{relative_to_root(bin)} (#{File.size(bin)} bytes)"}
    else
      tail = io.to_s.lines.last(6).join("\n")
      {false, tail.empty? ? "exit #{status.exit_code}" : tail}
    end
  end

  # Run an example headlessly with *env* set, producing *out*. Returns {ok, msg}.
  # Used for both stills (CRYSTERM_SHOT) and animations (CRYSTERM_ANIM).
  #
  # We `crystal build` to a *unique* temp binary and then exec it, rather than
  # `crystal run` — because two examples that share a basename (e.g. the
  # `status_bar.cr` of both `Widget::StatusBar` and `Pine::StatusBar`) would race
  # on `crystal run`'s basename-derived temp executable under `--jobs`. The
  # compile cache stays shared/warm; only the output binary is per-job.
  def self.capture_run(example_cr : String, dest : String, env : Process::Env) : {Bool, String}
    bin = File.tempname("crysterm-ex", "")
    io = IO::Memory.new
    build = Process.run("crystal", ["build", "--no-color", example_cr, "-o", bin],
      output: io, error: io, chdir: ROOT)
    unless build.success? && File.exists?(bin)
      return {false, io.to_s.lines.last(6).join("\n").presence || "build failed (exit #{build.exit_code})"}
    end
    run_io = IO::Memory.new
    status = Process.run(bin, env: env, output: run_io, error: run_io)
    File.delete(bin) rescue nil
    File.delete("#{bin}.dwarf") rescue nil
    if status.success? && File.exists?(dest)
      {true, "#{relative_to_root(dest)} (#{File.size(dest)} bytes)"}
    else
      tail = run_io.to_s.lines.last(6).join("\n")
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
    if opts.copy
      copy_docs_assets
      return
    end
    if opts.docs
      build_docs
      return
    end

    # `--force` with no mode flag re-runs the entire pipeline end to end:
    # (re)generate every example file, shoot the stills, record the APNGs,
    # refresh the in-source doc-comment captures, then build and populate the
    # docs tree. A mode flag (or `--no-shot`/`--shots-only`) instead scopes the
    # run to just that step, as before.
    if opts.full_chain?
      puts "── full chain: generate → stills → anims → doc-comments → docs ──"
      process(widgets, opts) # (re)generate example files + still PNGs
      anim_opts = opts.dup
      anim_opts.anim = true
      anim_opts.shots_only = true # files already (re)written by the stills pass
      process(widgets, anim_opts) # record the APNGs
      maintain_doc_comments(widgets)
      build_docs
      return
    end

    # A bare run (no flags): fill in only what's missing, then refresh the docs.
    if opts.default_run?
      process(widgets, opts) # generate missing example files + stills
      build_docs             # `crystal docs` + copy examples into the docs tree
      return
    end

    process(widgets, opts)
  end

  # The generation + capture/build phase, shared by a normal single-mode run and
  # by each step of the `--force` full chain.
  def self.process(widgets : Array(Item), opts : Options)
    generated = 0
    skipped = 0
    generics = [] of String
    no_script = [] of String
    # Examples to capture, collected during the (sequential) generation phase and
    # run in parallel afterwards. Each is {item, example.cr, output, env}.
    captures = [] of {Item, String, String, Process::Env}
    # Examples to compile, when --build/--release. Each is {item, example.cr, bin}.
    builds = [] of {Item, String, String}

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

        next if opts.no_shot && !opts.build
        next unless File.exists?(path) # nothing to do (shots-only, missing file)

        # Existing outputs are preserved unless --force (same rule as the .cr).
        if opts.build
          bin = build_path(w, idx)
          if skip_output?(bin, opts.force)
            skipped += 1
          else
            builds << {w, path, bin}
          end
        elsif opts.anim
          # Every example gets an APNG. Scripted ones play their demo; the rest
          # are recorded as a static hold (still capturing any self-animation).
          no_script << w.basename unless recipes[idx].script
          dest = anim_path(w, idx, opts.duration)
          if skip_output?(dest, opts.force)
            skipped += 1
          else
            captures << {w, path, dest, {"CRYSTERM_ANIM" => dest, "CRYSTERM_ANIM_SECS" => opts.duration.to_s}}
          end
        else
          dest = screenshot_path(w, idx)
          if skip_output?(dest, opts.force)
            skipped += 1
          else
            captures << {w, path, dest, {"CRYSTERM_SHOT" => dest}}
          end
        end
      end
    end

    # `--build` compiles instead of capturing.
    if opts.build
      build_ok = 0
      build_fail = 0
      bfailures = [] of String
      unless builds.empty?
        mode = opts.release ? "release" : "debug"
        puts "building #{builds.size} example(s) [#{mode}] with #{Math.min(opts.jobs, builds.size)} job(s)..."
        parallel_each(builds, opts.jobs) do |(w, path, bin)|
          ok, msg = build_example(path, bin, opts.release)
          if ok
            build_ok += 1
            puts "build  #{msg}"
          else
            build_fail += 1
            bfailures << w.basename
            puts(String.build do |io|
              io << "FAIL   " << relative_to_root(path)
              msg.each_line { |l| io << "\n         " << l }
            end)
          end
        end
      end
      puts
      puts "Summary: #{generated} written, #{skipped} skipped, #{build_ok} built, #{build_fail} failed."
      puts "Build failures: #{bfailures.uniq.join(", ")}" unless bfailures.empty?
      return
    end

    ok_n = 0
    fail_n = 0
    failures = [] of String
    verb = opts.anim ? "anim " : "shot "
    unless captures.empty?
      puts "#{opts.anim ? "recording" : "shooting"} #{captures.size} example(s) with #{Math.min(opts.jobs, captures.size)} job(s)..."
      parallel_each(captures, opts.jobs) do |(w, path, dest, env)|
        ok, msg = capture_run(path, dest, env)
        if ok
          ok_n += 1
          puts "#{verb}  #{msg}"
        else
          fail_n += 1
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
    captured = opts.anim ? "anims" : "shots"
    puts "Summary: #{generated} written, #{skipped} skipped, " \
         "#{ok_n} #{captured} ok, #{fail_n} #{captured} failed."
    unless failures.empty?
      puts "Build/capture failures (need a working recipe): #{failures.uniq.join(", ")}"
    end
    if opts.anim && !no_script.empty?
      puts "Recorded as a static hold (no demo script — add `script:` to its recipe to drive it): #{no_script.uniq.join(", ")}"
    end
    unless generics.empty?
      puts "Using the generic template (groom into real recipes): #{generics.uniq.join(", ")}"
    end
  end
end

WidgetExamples.run(ARGV)
