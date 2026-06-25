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
#   2. For an item that has *no* example yet, scaffolds one starter file into
#      that directory (`button.cr`) from a generic template. THIS IS THE ONLY
#      FILE THE TOOL EVER WRITES. From then on the example files in `examples/`
#      are the source of truth — hand-edited in place (add CSS, a demo `script`,
#      extra `button2.cr`, …); the tool never rewrites them.
#   3. Renders each example headlessly and, by default, saves all three captures
#      beside it — produced in ONE example run (one compile, one process):
#        * `<stem>-capture.png`        — still PNG
#        * `<stem>-capture<secs>s.apng` — APNG (scripted ones play their demo,
#                                         the rest a static hold)
#        * `<stem>-capture.dump`        — text golden (a frame per scripted
#                                         action; diffable via git)
#      Scope to one kind with `--shot`/`--anim`/`--dump`. All go through the
#      shared harness in `examples/<kind>/example.cr`, gated by the dest env vars
#      CRYSTERM_SHOT / CRYSTERM_ANIM / CRYSTERM_DUMP.
#   4. `--build`/`--release` compile every example (a build-health check).
#   5. `--doc-comments` embeds each item's capture in its API docs by maintaining
#      a fenced block in the class doc comment; `--docs` runs `crystal docs` and
#      copies `examples/` into the docs tree.
#
# The example programs live (and are maintained) in `examples/`; the tool only
# scaffolds the ones that are missing and (re)produces their captures/docs.
#
# Usage:
#   crystal run tools/manage-examples.cr -- [options] [name ...]
#
# Options:
#   -f, --force         Re-do outputs that already exist (stills/anims/binaries,
#                       and the docs build). Never overwrites an example .cr.
#       --only NAME     Restrict to NAME (repeatable; bare args work too).
#       --no-shot       Scaffold missing files but skip screenshots.
#       --shots-only    Only (re)capture; don't author any files.
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
  # Standalone programs (not registered widgets/layouts, not docs material). The
  # tool only (re)captures them — see `process_tests`.
  TESTS_DIR = File.join(ROOT, "tests")
  # The single shared example harness; every generated example requires it.
  HELPER = File.join(ROOT, "examples", "widget", "example")

  # ---- kinds ----------------------------------------------------------------

  # A category of documented thing the tool mirrors and exemplifies the same way.
  # `widget`s render standalone; `layout`s are installed on a container and
  # arrange its children (so their scaffold templates differ).
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

  # ---- scaffold templates ---------------------------------------------------
  #
  # The tool no longer carries a per-widget recipe registry — every example is
  # hand-maintained under `examples/`. What remains is a single *generic* starter
  # template per kind, used only to scaffold a brand-new item's first example
  # file (which is then edited in place).

  # The CSS + construction body of a scaffolded starter. `%{fqn}` / `%{klass}` /
  # `%{name}` are interpolated into both.
  record Recipe, css : String?, body : String

  # The starter for a widget with no example yet: a plain Box-style construction.
  # It compiles for the many widgets that inherit Box's `content:` constructor.
  #
  # It fills (almost) the whole screen on purpose. Many widgets lay out their own
  # fixed-position children (ColorDialog, Wizard, ...); a small box would let
  # those children spill past its border and paint garbage onto the screen. A
  # full-screen box keeps them in bounds, so the scaffolded shot is never broken
  # — just plain, until a human gives it a tailored size/content in place.
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

  # Layouts aren't standalone widgets: each is installed on a container via
  # `layout:` and arranges the container's children. So a scaffolded layout
  # example builds a full-screen container with the layout, then drops a handful
  # of labeled, bordered child boxes into it — enough to actually *show* the
  # arrangement. A human then tailors per-child placement hints (Grid columns,
  # Border regions, Form rows) in the scaffolded file as needed.
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

  # The generic example for an item, dispatched by kind. This is the *only*
  # template the tool still carries: it scaffolds a starter `<name>.cr` for a
  # widget/layout that has no example yet. Once written, the file in `examples/`
  # is the source of truth — edit it in place; the tool never rewrites it.
  def self.generic_recipe(w : Item) : Recipe
    w.kind.name == "layout" ? generic_layout_recipe(w) : generic_widget_recipe(w)
  end

  # The example *program* files for an item — the `<name>.cr`, `<name>2.cr`, …
  # under its `examples/` directory, in order. These are the hand-maintained
  # source of truth that the capture/build/doc steps run; an empty result means
  # the item has no example yet (and `#process` scaffolds one). The shared
  # `example.cr` harness lives a level up, so it never appears here, but it's
  # excluded defensively.
  def self.program_files(w : Item) : Array(String)
    dir = example_dir(w)
    return [] of String unless Dir.exists?(dir)
    Dir.glob(File.join(dir, "#{w.basename}*.cr"))
      .reject { |p| File.basename(p) == "example.cr" }
      .sort_by { |p| File.basename(p).size } # "foo.cr" before "foo2.cr" before "foo10.cr"
  end

  # Whether an item already has at least one hand-written example file.
  def self.example?(w : Item) : Bool
    !program_files(w).empty?
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

  # ---- output paths ---------------------------------------------------------
  #
  # Every capture/build output is named after its example *program* file's stem:
  # `foo.cr` -> `foo-capture.png` / `foo-capture5s.apng` / `foo` (binary), and
  # `foo2.cr` -> `foo2-capture.png`, … So the program file alone determines all
  # of its outputs — no separate index bookkeeping.

  # The program file's stem, e.g. `".../foo2.cr"` -> `"foo2"`.
  def self.prog_stem(prog : String) : String
    File.basename(prog, ".cr")
  end

  # Where *prog*'s still screenshot goes: `<stem>-capture.png`.
  def self.shot_for(prog : String) : String
    File.join(File.dirname(prog), "#{prog_stem(prog)}-capture.png")
  end

  # Where *prog*'s animation goes: `<stem>-capture<secs>s.apng`
  # (e.g. `list-capture5s.apng`; `<secs>` is the recording duration).
  def self.anim_for(prog : String, duration : Int32) : String
    File.join(File.dirname(prog), "#{prog_stem(prog)}-capture#{duration}s.apng")
  end

  # Where *prog*'s text dump goes: `<stem>-capture.dump` (same place/logic as the
  # PNG/APNG, just a plain-text golden — see `WidgetExample.dump_run`).
  def self.dump_for(prog : String) : String
    File.join(File.dirname(prog), "#{prog_stem(prog)}-capture.dump")
  end

  # Where *prog*'s compiled binary goes (`--build`): `<stem>` next to the source.
  def self.bin_for(prog : String) : String
    File.join(File.dirname(prog), prog_stem(prog))
  end

  # ---- scaffolding ----------------------------------------------------------

  # Render a starter example file for an item that has none yet, from the
  # generic template. This is the *only* file the tool ever writes; thereafter
  # the example is hand-maintained in place.
  def self.render_stub(w : Item) : String
    recipe = generic_recipe(w)
    req = helper_require(w)
    interp = ->(s : String) {
      s.gsub("%{fqn}", w.fqn).gsub("%{klass}", w.klass).gsub("%{name}", w.basename)
    }
    body = reindent(interp.call(recipe.body).rstrip, "  ")
    css = recipe.css.try { |c| interp.call(c) }

    String.build do |io|
      io << "# Example: " << w.fqn << "\n"
      io << "#\n"
      io << "# Minimal, self-contained example of a single " << w.klass << ".\n"
      io << "# Run it:     crystal run " << relative_to_root(File.join(example_dir(w), "#{w.basename}.cr")) << "\n"
      io << "# Scaffolded by tools/manage-examples.cr — now edit it here, in place.\n"
      io << "require \"" << req << "\"\n\n"
      io << "Crysterm::WidgetExample.run " << w.klass.inspect << " do |screen|\n"
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
  # the animation (`<stem>-capture<secs>s.apng`, which browsers play inline) and
  # falls back to the still (`<stem>-capture.png`) when there is no APNG. One
  # entry per example program file that has a capture.
  def self.capture_filenames(w : Item) : Array(String)
    program_files(w).compact_map do |prog|
      stem = prog_stem(prog)
      apng = Dir.glob(File.join(example_dir(w), "#{stem}-capture*s.apng")).sort.first?
      next File.basename(apng) if apng
      png = shot_for(prog)
      File.exists?(png) ? File.basename(png) : nil
    end
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
    property shot = false
    property anim = false
    property dump = false
    property all = false
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
      !no_shot && !shots_only && !shot && !anim && !dump && !all && !build && !doc_comments && !docs && !copy && !list
    end

    # `--force` on its own (no step/mode flag) means "re-do the whole chain":
    # generate, capture all three outputs (still + APNG + dump), refresh
    # doc-comments, build docs. `--jobs`, `--duration` and name filters aren't
    # mode flags, so they may accompany it.
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
      when "--shot"         then o.shot = true
      when "--anim"         then o.anim = true
      when "--dump"         then o.dump = true
      when "--all"          then o.all = true
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

      -f, --force       re-do existing outputs (stills/anims/binaries/docs);
                        never overwrites an example .cr
          --only NAME   restrict to NAME (repeatable; bare args work too)
          --no-shot     scaffold missing files but skip screenshots
          --shots-only  only (re)take screenshots; don't author any files
          --shot        ONLY the still PNG (scope the run to one output kind)
          --anim        ONLY the APNG (scripted examples play their demo)
          --dump        ONLY the text golden (<stem>-capture.dump): a frame per
                        scripted action, diffable via git
          --all         all three explicitly (same as the default); combine the
                        scope flags above for any other subset
          --duration N  animation length in seconds (default 5)
          --build       compile each example next to its source (x/<prog>.cr -> x/<prog>)
          --release     like --build, but a crystal --release (optimized) build
      -j, --jobs N      screenshot/anim concurrency (default #{default_jobs}; each is a compile)
          --doc-comments insert/refresh each example's capture in its source
                        class doc comment (so `crystal docs` shows it)
          --docs        run `crystal docs`, then copy examples/ into docs/
          --copy        just copy examples/ into docs/ (skip `crystal docs`)
          --list        show the plan and exit
      -h, --help        this help

    Example files in examples/ are the source of truth — edit them in place; the
    tool only scaffolds the MISSING ones (from a generic template) and never
    rewrites an existing .cr.
    With NO flags: scaffold missing examples, produce every MISSING output
    (still + APNG + dump, one run each), then build docs.
    -f/--force on its OWN (no mode flag) re-does the whole chain end to end:
    scaffold -> still+APNG+dump -> doc-comments -> docs. Pair --force with a
    scope flag to force just that kind (e.g. `--force --dump`).
    --doc-comments and --docs run only their own step.
    [name ...], --jobs and --duration may accompany any of the above.
    So day to day you only need `--force` and/or a name filter; the rest is
    automatic.

    tests/ : every .cr under tests/ is also (re)captured to png/apng/dump next
    to itself on any capturing run — no scaffolding, doc-comments or docs (it
    is not docs material). The same scope/force/duration/jobs/name flags apply.
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

  # Run an example headlessly with *env* set, producing every file in *dests* in
  # ONE process. *env* holds whichever of `CRYSTERM_SHOT`/`CRYSTERM_DUMP`/
  # `CRYSTERM_ANIM` were requested; the harness emits all of them in a single run,
  # so `--all` costs one compile + one exec instead of one per output kind.
  # Returns {ok, msg}.
  #
  # We `crystal build` to a *unique* temp binary and then exec it, rather than
  # `crystal run` — because two examples that share a basename (e.g. the
  # `status_bar.cr` of both `Widget::StatusBar` and `Pine::StatusBar`) would race
  # on `crystal run`'s basename-derived temp executable under `--jobs`. The
  # compile cache stays shared/warm; only the output binary is per-job.
  def self.capture_run(example_cr : String, dests : Array(String), env : Process::Env) : {Bool, String}
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
    missing = dests.reject { |d| File.exists?(d) }
    if status.success? && missing.empty?
      {true, dests.map { |d| "#{relative_to_root(d)} (#{File.size(d)} bytes)" }.join(", ")}
    else
      tail = run_io.to_s.lines.last(6).join("\n")
      detail = tail.presence || (missing.empty? ? "exit #{status.exit_code}" : "did not produce #{missing.map { |d| relative_to_root(d) }.join(", ")}")
      {false, detail}
    end
  end

  # ---- main -----------------------------------------------------------------

  def self.run(argv : Array(String))
    opts = parse_options(argv)
    all = discover
    widgets = all.select { |w| opts.matches?(w) }

    if widgets.empty? && matching_tests(opts).empty?
      STDERR.puts "no matching widgets or tests (#{all.size} widgets discovered)"
      exit 1
    end

    if opts.list
      puts "#{widgets.size} widget(s):"
      widgets.each do |w|
        n = program_files(w).size
        status = n == 0 ? "missing" : (n == 1 ? "example" : "#{n} examples")
        puts "  %-22s %-32s [%s] -> %s" % [
          w.basename, w.fqn, status, relative_to_root(example_dir(w)),
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
    # scaffold any still-missing example, (re)shoot the stills, (re)record the
    # APNGs, refresh the in-source doc-comment captures, then build and populate
    # the docs tree. Existing example .cr files are never rewritten. A mode flag
    # (or `--no-shot`/`--shots-only`) instead scopes the run to just that step.
    if opts.full_chain?
      puts "── full chain: scaffold → still+APNG+dump → doc-comments → docs ──"
      process(widgets, opts) # one run per example produces all three outputs
      process_tests(opts)    # tests/: captures only (no scaffold/doc-comments/docs)
      # Doc-comments and docs are a widget/layout concern. When the filter
      # selected no widgets (e.g. `--only tests/blessed-test/`), this is a
      # tests-only run — skip them so it doesn't rebuild the whole docs tree.
      unless widgets.empty?
        maintain_doc_comments(widgets)
        build_docs
      end
      return
    end

    # A bare run (no flags): fill in only what's *missing* (all three output
    # kinds), then refresh the docs.
    if opts.default_run?
      process(widgets, opts)           # generate missing example files + still/APNG/dump
      process_tests(opts)              # tests/: produce any missing captures
      build_docs unless widgets.empty? # `crystal docs` + copy examples (widgets only)
      return
    end

    process(widgets, opts)
    # `--build` only applies to the registered examples (compiled next to their
    # source); for every other scope flag (`--shot`/`--anim`/`--dump`/`--all`/
    # `--shots-only`) also (re)capture the tests.
    process_tests(opts) unless opts.build
  end

  # The generation + capture/build phase, shared by a normal single-mode run and
  # by each step of the `--force` full chain.
  def self.process(widgets : Array(Item), opts : Options)
    scaffolded = 0
    skipped = 0
    stubs = [] of String
    no_script = [] of String
    # Examples to capture, collected during the (sequential) scan phase and run
    # in parallel afterwards. Each is {item, example.cr, output, env}.
    captures = [] of {Item, String, Array(String), Process::Env}
    # Examples to compile, when --build/--release. Each is {item, example.cr, bin}.
    builds = [] of {Item, String, String}

    widgets.each do |w|
      progs = program_files(w)

      # The example files in `examples/` are the source of truth — never
      # rewritten. A widget with *no* example yet gets one starter scaffolded
      # from the generic template, after which it is hand-maintained in place.
      # A `--shots-only`/`--build` pass mustn't author sources, so it skips an
      # un-exemplified widget rather than scaffolding it.
      if progs.empty?
        next if opts.shots_only
        FileUtils.mkdir_p(example_dir(w))
        path = File.join(example_dir(w), "#{w.basename}.cr")
        File.write(path, render_stub(w))
        scaffolded += 1
        stubs << w.basename
        puts "scaffold #{relative_to_root(path)} (now edit it in place)"
        progs = [path]
      end

      progs.each do |path|
        next if opts.no_shot && !opts.build

        # `--build` compiles instead of capturing (its own, separate output).
        if opts.build
          bin = bin_for(path)
          if skip_output?(bin, opts.force)
            skipped += 1
          else
            builds << {w, path, bin}
          end
          next
        end

        # Which capture outputs this run wants. The DEFAULT (no mode flag) is
        # *all* of them — still + APNG + dump — so a bare run (or `--force`) just
        # produces everything. A specific flag (`--shot`/`--anim`/`--dump`, or
        # `--all`) scopes the run to that subset. Whatever the set, it is produced
        # by a SINGLE example run (one compile, one process): the harness honors
        # every dest env var set.
        explicit = opts.shot || opts.anim || opts.dump || opts.all
        want_shot = opts.shot || opts.all || !explicit
        want_anim = opts.anim || opts.all || !explicit
        want_dump = opts.dump || opts.all || !explicit

        no_script << prog_stem(path) if want_anim && !File.read(path).includes?("script:")

        env = {} of String => String
        dests = [] of String
        if want_shot
          d = shot_for(path)
          skip_output?(d, opts.force) ? (skipped += 1) : (env["CRYSTERM_SHOT"] = d; dests << d)
        end
        if want_dump
          d = dump_for(path)
          skip_output?(d, opts.force) ? (skipped += 1) : (env["CRYSTERM_DUMP"] = d; dests << d)
        end
        if want_anim
          d = anim_for(path, opts.duration)
          if skip_output?(d, opts.force)
            skipped += 1
          else
            env["CRYSTERM_ANIM"] = d
            env["CRYSTERM_ANIM_SECS"] = opts.duration.to_s
            dests << d
          end
        end

        captures << {w, path, dests, env} unless dests.empty?
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
      puts "Summary: #{scaffolded} scaffolded, #{skipped} skipped, #{build_ok} built, #{build_fail} failed."
      puts "Build failures: #{bfailures.uniq.join(", ")}" unless bfailures.empty?
      return
    end

    ok_n = 0
    fail_n = 0
    failures = [] of String
    unless captures.empty?
      puts "capturing #{captures.size} example(s) with #{Math.min(opts.jobs, captures.size)} job(s)..."
      parallel_each(captures, opts.jobs) do |(w, path, dests, env)|
        ok, msg = capture_run(path, dests, env)
        if ok
          ok_n += 1
          puts "wrote  #{msg}"
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
    puts "Summary: #{scaffolded} scaffolded, #{skipped} skipped, " \
         "#{ok_n} captured ok, #{fail_n} failed."
    unless failures.empty?
      puts "Build/capture failures (the example needs fixing): #{failures.uniq.join(", ")}"
    end
    if (opts.anim || opts.all) && !no_script.empty?
      puts "Recorded as a static hold (no demo script — add a `script:` to the example to drive it): #{no_script.uniq.join(", ")}"
    end
    unless stubs.empty?
      puts "Scaffolded from the generic template (flesh out in place): #{stubs.uniq.join(", ")}"
    end
  end

  # ---- tests ----------------------------------------------------------------

  # `tests/` holds standalone programs — not registered widgets/layouts, and not
  # docs material — so the tool's *only* job there is to (re)produce the three
  # capture artifacts next to each `.cr`: `<stem>-capture.png`,
  # `<stem>-capture.dump`, and `<stem>-capture<secs>s.apng`. No scaffolding, no
  # doc-comments, no docs. Each program captures itself headlessly via the
  # `CRYSTERM_SHOT`/`CRYSTERM_DUMP`/`CRYSTERM_ANIM` env vars honored by
  # `Screen#exec`. Output scoping (`--shot`/`--anim`/`--dump`/`--all`/default),
  # `--force`, `--duration`, `--jobs` and name filters all apply, exactly as for
  # examples. `--build` is a no-op here (tests are run, not compiled to binaries).
  # All `tests/**/*.cr` programs the current name filters select (every test when
  # no filter is given). Shared by `process_tests` and `run`'s emptiness check.
  def self.matching_tests(opts : Options) : Array(String)
    return [] of String unless Dir.exists?(TESTS_DIR)
    progs = Dir.glob(File.join(TESTS_DIR, "**", "*.cr")).sort
    return progs if opts.filters.empty?
    # A filter matches a test if it's a substring of the test's full path, so a
    # stem (`widget-bigtext`), a path fragment (`blessed-test/widget-dock`) or a
    # directory (`tests/blessed-test/`) all select the expected files.
    progs.select do |p|
      pl = p.downcase
      opts.filters.any? { |f| pl.includes?(f.downcase) }
    end
  end

  def self.process_tests(opts : Options)
    progs = matching_tests(opts)
    return if progs.empty?

    explicit = opts.shot || opts.anim || opts.dump || opts.all
    want_shot = opts.shot || opts.all || !explicit
    want_anim = opts.anim || opts.all || !explicit
    want_dump = opts.dump || opts.all || !explicit

    skipped = 0
    captures = [] of {String, Array(String), Hash(String, String)}
    progs.each do |prog|
      env = {} of String => String
      dests = [] of String
      if want_shot
        d = shot_for(prog)
        skip_output?(d, opts.force) ? (skipped += 1) : (env["CRYSTERM_SHOT"] = d; dests << d)
      end
      if want_dump
        d = dump_for(prog)
        skip_output?(d, opts.force) ? (skipped += 1) : (env["CRYSTERM_DUMP"] = d; dests << d)
      end
      if want_anim
        d = anim_for(prog, opts.duration)
        if skip_output?(d, opts.force)
          skipped += 1
        else
          env["CRYSTERM_ANIM"] = d
          env["CRYSTERM_ANIM_SECS"] = opts.duration.to_s
          dests << d
        end
      end
      captures << {prog, dests, env} unless dests.empty?
    end

    return if captures.empty?
    puts "capturing #{captures.size} test(s) with #{Math.min(opts.jobs, captures.size)} job(s)..."
    ok_n = 0
    fail_n = 0
    failures = [] of String
    parallel_each(captures, opts.jobs) do |(prog, dests, env)|
      ok, msg = capture_run(prog, dests, env)
      if ok
        ok_n += 1
        puts "wrote  #{msg}"
      else
        fail_n += 1
        failures << prog_stem(prog)
        puts(String.build do |io|
          io << "FAIL   " << relative_to_root(prog)
          msg.each_line { |l| io << "\n         " << l }
        end)
      end
    end
    puts "Tests: #{ok_n} captured ok, #{fail_n} failed, #{skipped} skipped."
    puts "Test capture failures (the program needs fixing): #{failures.uniq.join(", ")}" unless failures.empty?
  end
end

WidgetExamples.run(ARGV)
