#!/usr/bin/env crystal
#
# test.cr — (re)produce the captures for Crysterm example programs.
#
# Point it at one or more directories and/or individual `.cr` programs.
#
# A directory is walked recursively, and in every directory at or below it the
# programs to run are picked as:
#
#   * if the dir has a file of the same name (`foo/foo.cr`), that is THE program
#     and the dir's other `.cr` files are its support code (untouched);
#   * otherwise every `.cr` directly in the dir is its own program.
#
# A `.cr` file names that one program directly, skipping discovery — the quickest
# way to re-make a single program's captures (`tools/test.cr tests/misc/themes.cr`).
#
# Each program is compiled and run headlessly to (re)produce its captures beside
# it:
#
#     foo/foo.cr -> foo/foo.png         still PNG
#                   foo/foo.<secs>s.apng  APNG (e.g. foo.5s.apng)
#                   foo/foo.dump         text golden
#
# The program emits whichever outputs the dest env vars request
# (CRYSTERM_SHOT / CRYSTERM_ANIM / CRYSTERM_DUMP), all in a single run; --shot /
# --anim / --dump scope the run to a subset (default: all three). A capture is
# left alone when newer than its `.cr`, unless --force.
#
# Separately, `--doc-comments` embeds each widget's capture in its API docs via
# a fenced block in the source class doc comment, and `--docs` runs
# `crystal docs` then copies `examples/` into the docs tree.
#
# Invoked bare (no flags, no target), it runs the FULL pipeline: (re)capture
# stale outputs, then `--doc-comments`, then `--docs`. Any explicit action flag
# — or a named target (which scopes capture) — narrows the run to just that.
#
# Usage: crystal run tools/test.cr -- [options] [dir|prog.cr ...]  (default: examples tests)

require "file_utils"

module WidgetExamples
  VERSION = "0.1.0"

  ROOT       = File.expand_path(File.join(__DIR__, ".."))
  WIDGETS_CR = File.join(ROOT, "src", "widgets.cr")

  # Directories captured when none are named on the command line.
  DEFAULT_DIRS = [File.join(ROOT, "examples"), File.join(ROOT, "tests")]

  # ---- program discovery ----------------------------------------------------

  # Every program named by *roots*, each of which is either a directory to walk
  # or a single `.cr` program to capture on its own.
  #
  # A **directory** is walked recursively, and in each directory at or below it:
  # a same-named file (`foo/foo.cr`) is the program and its other `.cr` files
  # are support code, left alone; otherwise every `.cr` directly in the dir is
  # its own program (the shared `example.cr` harness excepted).
  #
  # A **`.cr` file** is taken as that one program, verbatim. Naming a file is an
  # unambiguous statement of intent, so the directory heuristics above don't
  # apply to it: a support file or the `example.cr` harness still runs if that
  # is what was asked for. Whether its captures are actually re-made is the same
  # question as for a discovered program — `skip_output?` leaves outputs newer
  # than their `.cr` alone unless `--force`.
  #
  # Sorted and de-duped, so naming a file and the directory containing it
  # captures it once.
  def self.discover_programs(roots : Array(String)) : Array(String)
    progs = [] of String
    roots.each do |root|
      abs = File.expand_path(root)
      unless Dir.exists?(abs)
        progs << abs if abs.ends_with?(".cr") && File.exists?(abs)
        next
      end
      dirs = [abs] + Dir.glob(File.join(abs, "**", "*")).select { |p| Dir.exists?(p) }
      dirs.each do |dir|
        main = File.join(dir, "#{File.basename(dir)}.cr")
        if File.exists?(main)
          progs << main
        else
          progs.concat Dir.glob(File.join(dir, "*.cr")).reject { |p| File.basename(p) == "example.cr" }
        end
      end
    end
    progs.uniq.sort
  end

  # A named target that is neither an existing directory nor an existing `.cr`
  # file — reported up front so a typo'd path fails by name instead of silently
  # contributing no programs (and, alone, looking like "nothing to do").
  def self.unusable_targets(roots : Array(String)) : Array(String)
    roots.reject do |root|
      abs = File.expand_path(root)
      Dir.exists?(abs) || (abs.ends_with?(".cr") && File.exists?(abs))
    end
  end

  # ---- output paths ---------------------------------------------------------
  #
  # Every output is named after its program's stem, beside it: `foo.cr` ->
  # `foo.png` / `foo.<secs>s.apng` (e.g. `foo.5s.apng`) / `foo.dump` / `foo`
  # (binary).

  def self.prog_stem(prog : String) : String
    File.basename(prog, ".cr")
  end

  def self.shot_for(prog : String) : String
    File.join(File.dirname(prog), "#{prog_stem(prog)}.png")
  end

  def self.anim_for(prog : String, duration : Int32) : String
    File.join(File.dirname(prog), "#{prog_stem(prog)}.#{duration}s.apng")
  end

  def self.dump_for(prog : String) : String
    File.join(File.dirname(prog), "#{prog_stem(prog)}.dump")
  end

  def self.bin_for(prog : String) : String
    File.join(File.dirname(prog), prog_stem(prog))
  end

  def self.relative_to_root(path : String) : String
    path.starts_with?(ROOT) ? path[(ROOT.size + 1)..] : path
  end

  # ---- registered widgets/layouts (for doc-comments / docs) -----------------
  #
  # The doc steps map a screenshot back to the *source* class that owns it, so
  # they discover the registered widgets/layouts from `src/widgets.cr` (instead
  # of from the captured directories above).

  record Kind,
    name : String,    # "widget" / "layout"
    src : String,     # src dir, e.g. <root>/src/widget
    out_dir : String, # examples dir mirroring src, e.g. <root>/tests/widget
    base_ns : String  # "Crysterm::Widget" / "Crysterm::Layout"

  KINDS = [
    Kind.new("widget", File.join(ROOT, "src", "widget"), File.join(ROOT, "tests", "widget"), "Crysterm::Widget"),
    Kind.new("layout", File.join(ROOT, "src", "layout"), File.join(ROOT, "tests", "layout"), "Crysterm::Layout"),
  ]

  record Item,
    kind : Kind,
    klass : String,   # simple class name, e.g. "Box", "Bar", "HBox"
    fqn : String,     # "Crysterm::Widget::Graph::Bar" / "Crysterm::Layout::HBox"
    src : String,     # absolute path to the source .cr
    rel : String,     # path under the kind's src dir, no ext, e.g. "graph/bar"
    basename : String # "bar"

  # The example directory for an item: the kind's out_dir + the item's rel path
  # (e.g. tests/widget/button, examples/layout/hbox).
  def self.example_dir(w : Item) : String
    File.join(w.kind.out_dir, w.rel)
  end

  # The example program files for an item — `<name>.cr`, `<name>2.cr`, … under
  # its `examples/` directory. The shared `example.cr` harness lives a level up,
  # so it never appears here, but it's excluded defensively.
  def self.program_files(w : Item) : Array(String)
    dir = example_dir(w)
    return [] of String unless Dir.exists?(dir)
    Dir.glob(File.join(dir, "#{w.basename}*.cr"))
      .reject { |p| File.basename(p) == "example.cr" }
      .sort_by { |p| File.basename(p).size } # "foo.cr" before "foo2.cr" before "foo10.cr"
  end

  # Discover documented widgets/layouts by mirroring the example tree onto the
  # source. Each example program `<out_dir>/<rel>/<name>.cr` names one class; the
  # exact FQN is read from the example's own instantiation, so irregular
  # file<->class names (`lcd_number`<->`LCDNumber`) and nested
  # classes (`Media::Unicode::Braille`) resolve with no registry. The source file
  # is found by walking up the rel path (a nested variant's class lives in its
  # parent file: `media/glyph/braille` -> `media/glyph.cr`).
  def self.discover : Array(Item)
    items = [] of Item
    KINDS.each do |kind|
      next unless Dir.exists?(kind.out_dir)
      ns = kind.base_ns.lchop("Crysterm::") # "Widget" / "Layout"
      class_ref = /(?:Crysterm::)?#{ns}::[A-Za-z0-9_:]+/
      discover_programs([kind.out_dir]).each do |prog|
        dir = File.dirname(prog)
        next unless dir.size > kind.out_dir.size # skip any program directly in out_dir
        rel = dir[(kind.out_dir.size + 1)..]
        src = source_file_for(kind, rel)
        next unless src

        # FQNs this example instantiates (e.g. "Crysterm::Widget::Media::Unicode::Braille").
        candidates = File.read(prog).scan(class_ref).map do |m|
          f = m[0]
          f.starts_with?("Crysterm::") ? f : "Crysterm::#{f}"
        end.uniq
        # The subject is the candidate whose leaf class is declared in *src*
        # (rejects incidental references like the label `Widget::Box`).
        decl = File.read(src)
        subject = candidates.find do |fqn|
          leaf = fqn.split("::").last
          decl =~ /^\s*class\s+(?:[A-Z][A-Za-z0-9_]*::)*#{Regex.escape(leaf)}\b/m
        end
        next unless subject

        items << Item.new(
          kind: kind, klass: subject.split("::").last, fqn: subject,
          src: src, rel: rel, basename: File.basename(prog, ".cr"))
      end
    end
    items
  end

  # The source file declaring example *rel*'s class under *kind*: the mirrored
  # path `<src>/<rel>.cr`, or — when a nested variant's example sits deeper than
  # its source file — the nearest existing ancestor file.
  def self.source_file_for(kind : Kind, rel : String) : String?
    parts = rel.split('/')
    while !parts.empty?
      candidate = File.join(kind.src, parts.join('/')) + ".cr"
      return candidate if File.exists?(candidate)
      parts.pop
    end
    nil
  end

  # ---- doc-comment maintenance ----------------------------------------------
  #
  # Each widget's API docs (via `crystal docs`) get its screenshot embedded by a
  # managed block inside the *class doc comment* of its source file. The block
  # is fenced by HTML comments (invisible in rendered Markdown) so the tool can
  # find, refresh, or migrate it without disturbing hand-written prose:
  #
  #     # <!-- widget-examples:capture v1 -->
  #     # ![Button screenshot](../../tests/widget/button/button.5s.apng)
  #     # <!-- /widget-examples:capture -->
  #
  # `crystal docs` emits the `src` verbatim, resolved relative to the class's
  # generated page (`docs/Crysterm/Widget/Button.html`). `--docs` copies the
  # example trees (`tests/widget/`, `examples/layout/`, see DOCS_ASSETS) into
  # `docs/`; the `../` prefix (one per namespace level) walks from the page back
  # to the docs root, so the reference resolves with no network or per-page assets.

  # Bump when the block's rendered shape changes, so `--doc-comments` recognizes
  # and rewrites an older block. The migration matcher keys off the stable
  # `widget-examples:capture` token, so even the version label can change.
  DOC_VERSION = "v1"
  DOC_OPEN    = "<!-- widget-examples:capture #{DOC_VERSION} -->"
  DOC_CLOSE   = "<!-- /widget-examples:capture -->"

  # Migration-safe fence detection (matches any past/version of the block).
  DOC_OPEN_RE  = /<!--\s*widget-examples:capture\b[^>]*-->/
  DOC_CLOSE_RE = /<!--\s*\/\s*widget-examples:capture\b[^>]*-->/

  # The image each example contributes to the docs, as a bare filename. Prefers
  # the animation (`<stem>.<secs>s.apng`, which browsers play inline), falling
  # back to the still (`<stem>.png`). One entry per example program that has a
  # capture.
  def self.capture_filenames(w : Item) : Array(String)
    program_files(w).compact_map do |prog|
      stem = prog_stem(prog)
      apng = Dir.glob(File.join(example_dir(w), "#{stem}.*s.apng")).sort.first?
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
  # docs root, then into the copied example tree (`tests/widget/<rel>/`,
  # `examples/layout/<rel>/`).
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
  # plus any *case-only* alias (e.g. `alias Checkbox = CheckBox`). On a
  # case-insensitive filesystem `crystal docs` writes `Checkbox.html` and
  # `CheckBox.html` to the same file, so the alias page (no doc comment) would
  # otherwise clobber the class page's screenshot — document the alias too.
  # Each anchor is {line index, indentation}.
  def self.doc_anchors(lines : Array(String), klass : String) : Array({Int32, String})
    # Match the class by its leaf name, allowing a declared namespace prefix
    # (`class Media::Sixel` for klass `Sixel`); the leaf is anchored at an
    # identifier boundary so `class StackedBar` isn't matched for `Bar`.
    class_re = /^(\s*)class\s+(?:[A-Z][A-Za-z0-9_]*::)*#{Regex.escape(klass)}\b/
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

  # Insert/refresh the managed screenshot blocks for every documented class in
  # one source file at once — a file may host several (e.g. `Media::Glyph` plus
  # its nested `Block`/`Octant`/… variants), and `strip_managed_blocks` clears
  # *all* of them, so they must be re-inserted together or siblings get
  # clobbered. Returns a per-item outcome
  # (:inserted/:updated/:unchanged/:no_capture/:no_class).
  def self.maintain_doc_comments_in_file(src : String, items : Array(Item)) : Hash(Item, Symbol)
    original = File.read(src)
    lines = original.split('\n')
    had_block = strip_managed_blocks(lines)
    outcomes = {} of Item => Symbol

    # Collect every class's insertion against the (stripped) lines first, then
    # apply bottom-up so earlier indices stay valid. A blank-comment line
    # separates the image from existing prose; with none it becomes the anchor's
    # doc comment.
    insertions = [] of {Int32, Array(String)}
    items.each do |w|
      anchors = doc_anchors(lines, w.klass)
      if anchors.empty?
        outcomes[w] = :no_class
      elsif capture_filenames(w).empty?
        outcomes[w] = :no_capture
      else
        outcomes[w] = had_block ? :updated : :inserted
        anchors.each do |(idx, indent)|
          block = [] of String
          block << "#{indent}#" if idx > 0 && lines[idx - 1] =~ /^\s*#/
          block.concat doc_block_lines(w, indent).not_nil!
          insertions << {idx, block}
        end
      end
    end

    insertions.sort_by! { |(idx, _)| -idx }
    insertions.each { |(idx, block)| lines = lines[0...idx] + block + lines[idx..] }

    unless write_if_changed(src, original, lines)
      outcomes.each { |w, v| outcomes[w] = :unchanged if v.in?(:inserted, :updated) }
    end
    outcomes
  end

  def self.write_if_changed(path : String, original : String, lines : Array(String)) : Bool
    updated = lines.join('\n')
    return false if updated == original
    File.write(path, updated)
    true
  end

  # Maintain the managed screenshot blocks in every selected widget's source,
  # grouped per file, printing a one-line outcome per class.
  def self.maintain_doc_comments(widgets : Array(Item)) : Nil
    counts = Hash(Symbol, Int32).new(0)
    widgets.group_by(&.src).each do |src, group|
      maintain_doc_comments_in_file(src, group).each do |w, result|
        counts[result] += 1
        next if result == :unchanged
        verb = case result
               when :inserted   then "doc+   "
               when :updated    then "doc~   "
               when :no_capture then "doc?   "
               when :no_class   then "doc!   "
               else                  "doc    "
               end
        note = result == :no_class ? " (no `class #{w.klass}` found)" : result == :no_capture ? " (no screenshot yet)" : ""
        puts "#{verb}#{relative_to_root(w.src)} (#{w.klass})#{note}"
      end
    end
    puts
    puts "Doc comments: #{counts[:inserted]} inserted, #{counts[:updated]} updated, " \
         "#{counts[:unchanged]} unchanged, #{counts[:no_capture]} without a shot, " \
         "#{counts[:no_class]} unresolved."
  end

  # ---- docs build + asset copy ----------------------------------------------

  # Source trees (relative to the project root) copied verbatim into `docs/` so
  # the doc-comment image references resolve. `tests/widget/` carries the
  # screenshots; add more here if other docs reference in-repo assets.
  DOCS_ASSETS = ["tests/widget", "examples/layout"]

  # Run `crystal docs`, then mirror DOCS_ASSETS into the generated tree. The
  # shard entry is passed explicitly because bare `crystal docs` mis-resolves
  # the file set on this project (documents src files in an order that leaves
  # `Mixin::*` constants undefined) and fails.
  def self.build_docs : Nil
    args = ["docs", "src/crysterm.cr"]
    echo_cmd "crystal", args
    status = Process.run("crystal", args, output: STDOUT, error: STDERR, chdir: ROOT)
    exit 1 unless status.success?
    copy_docs_assets
  end

  # Mirror DOCS_ASSETS into the (already-built) docs tree
  # (`tests/widget/` -> `docs/tests/widget/`, …), without re-running
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
    property shot = false
    property anim = false
    property dump = false
    property all = false
    property build = false
    property release = false
    property doc_comments = false
    property docs = false
    property copy = false
    property list = false
    property test = false
    property duration = 5
    property jobs = WidgetExamples.default_jobs
    # Named capture targets: directories to walk, and/or individual `.cr`
    # programs. Empty means the `DEFAULT_DIRS` roots.
    property targets = [] of String
  end

  def self.parse_options(argv : Array(String)) : Options
    o = Options.new
    i = 0
    while i < argv.size
      arg = argv[i]
      case arg
      when "-f", "--force"  then o.force = true
      when "--shot"         then o.shot = true
      when "--anim"         then o.anim = true
      when "--dump"         then o.dump = true
      when "--all"          then o.all = true
      when "--build"        then o.build = true
      when "--release"      then o.release = true; o.build = true
      when "--doc-comments" then o.doc_comments = true
      when "--docs"         then o.docs = true
      when "--copy"         then o.copy = true
      when "--list"         then o.list = true
      when "--test"         then o.test = true
      when "--duration"
        i += 1
        o.duration = (i < argv.size ? argv[i].to_i? : nil) || o.duration
        o.duration = 1 if o.duration < 1
      when "-j", "--jobs"
        i += 1
        o.jobs = (i < argv.size ? argv[i].to_i? : nil) || o.jobs
        o.jobs = 1 if o.jobs < 1
      when "-h", "--help"
        puts HELP
        exit 0
      else
        if arg.starts_with?("-")
          STDERR.puts "unknown option: #{arg}"
          exit 2
        end
        o.targets << arg
      end
      i += 1
    end
    o
  end

  HELP = <<-TXT
    test.cr v#{VERSION} — (re)produce captures for example programs.

    Usage: crystal run tools/test.cr -- [options] [dir|prog.cr ...]

    Invoked bare (no flags, no TARGET), it runs the FULL pipeline: (re)capture
    stale outputs, then --doc-comments, then --docs. Any explicit action flag — or
    a named TARGET (which scopes capture) — narrows the run to just that step.

    A TARGET is a directory or a single .cr program (default: examples tests).

    For every directory at or below a named dir: if it has a program of the same
    name (foo/foo.cr) that one runs (the dir's other .cr are its support code);
    otherwise each .cr in the dir runs on its own. A named .cr file is that one
    program, no discovery — the quickest way to redo one program's captures:

        crystal run tools/test.cr -- --force tests/misc/themes.cr

    Each program is compiled and run headlessly to (re)produce its captures beside
    it: foo.png, foo.<secs>s.apng and foo.dump. An output newer than its .cr is
    left alone unless --force — note the check only sees the program's own source,
    not the library, so after a change under src/ you want --force.

      -f, --force       re-make outputs even when up to date
          --shot        only the still PNG
          --anim        only the APNG
          --dump        only the text golden (foo.dump)
          --all         all three (the default); combine the scope flags for a subset
          --duration N  animation length in seconds (default 5)
          --build       compile each program next to its source (foo/foo.cr -> foo/foo)
          --release     like --build, but an optimized (--release) build
      -j, --jobs N      compile concurrency for capture/build (default #{default_jobs};
                        capture runs are always serial — realtime fidelity)
          --doc-comments insert/refresh each widget's capture in its source class
                        doc comment (so `crystal docs` shows it)
          --docs        run `crystal docs`, then copy examples/ into docs/
          --copy        just copy examples/ into docs/ (skip `crystal docs`)
          --list        list the programs that would run, and exit
          --test        generate any missing outputs, then print `git status` for
                        the dirs; exit non-zero if anything changed (CI check)
      -h, --help        this help
    TXT

  # ---- capture / build ------------------------------------------------------

  # Default concurrency. Each job is a full `crystal` compile — RAM heavy
  # (~8 GB peak on this codebase) — so cap by physical RAM as well as cores:
  # cores alone let a 10-core/32 GB machine run 8 compiles at once, committing
  # ~70 GB and grinding the whole box into swap. Override with `--jobs`.
  def self.default_jobs : Int32
    by_cores = Math.min(8, System.cpu_count.to_i - 1)
    # One job per ~12 GB of physical RAM (compile peak + headroom).
    by_ram = physical_memory.try { |b| (b // 12_000_000_000).to_i } || by_cores
    Math.max(1, Math.min(by_cores, by_ram))
  end

  # Physical RAM in bytes, or `nil` when it can't be determined.
  def self.physical_memory : Int64?
    {% if flag?(:darwin) %}
      `sysctl -n hw.memsize`.strip.to_i64?
    {% else %}
      File.read_lines("/proc/meminfo")
        .find(&.starts_with?("MemTotal:"))
        .try { |l| l.split[1]?.try &.to_i64?.try &.*(1024) }
    {% end %}
  rescue
    nil
  end

  # Run *work* over *items* with at most *jobs* fibers in flight. Each fiber's
  # `crystal` subprocess runs in parallel via the OS while the fibers stay
  # cooperative (single-threaded), so shared counters need no locking.
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

  # An output may be skipped when it exists and is at least as new as its program
  # source (unless --force).
  def self.skip_output?(dest : String, src : String, force : Bool) : Bool
    return false if force || !File.exists?(dest)
    File.info(dest).modification_time >= File.info(src).modification_time
  end

  # Echo an external command — its argv plus any env overrides as `VAR=value`
  # prefixes — the way a shell would, right before it runs.
  def self.echo_cmd(cmd : String, args : Array(String), env = nil) : Nil
    parts = [] of String
    env.try &.each { |k, v| parts << "#{k}=#{Process.quote(v.to_s)}" if v }
    parts << Process.quote([cmd] + args)
    puts parts.join(" ")
  end

  # Compile *program* to *bin* (optionally `--release`). Returns whether it built.
  def self.build_example(program : String, bin : String, release : Bool) : Bool
    args = ["build", "--no-color", program, "-o", bin]
    args << "--release" if release
    echo_cmd "crystal", args
    Process.run("crystal", args, output: STDOUT, error: STDERR, chdir: ROOT).success? && File.exists?(bin)
  end

  # Compile *program* to a unique temp binary for a capture run; returns the
  # binary path, or nil when the build failed.
  #
  # `crystal build` to a *unique* temp binary and exec it, rather than
  # `crystal run`, because two programs sharing a basename would race on
  # `crystal run`'s basename-derived temp executable under `--jobs`. The
  # compile cache stays shared/warm; only the output binary is per-job.
  def self.capture_build(program : String) : String?
    bin = File.tempname("crysterm-ex", "")
    build_args = ["build", "--no-color", program, "-o", bin]
    echo_cmd "crystal", build_args
    build = Process.run("crystal", build_args, output: STDOUT, error: STDERR, chdir: ROOT)
    return unless build.success? && File.exists?(bin)
    bin
  end

  # Run one prebuilt capture binary headlessly with *env* set, producing every
  # file in *dests* in ONE process. *env* holds whichever of `CRYSTERM_SHOT`/
  # `CRYSTERM_DUMP`/`CRYSTERM_ANIM` were requested; the harness emits all of
  # them in a single run, so the default costs one compile + one exec instead
  # of one per kind. Deletes the binary afterwards.
  #
  # The captured program self-renders only when headless, auto-detected from
  # `STDOUT.tty?` (`Crysterm.interactive?`), so its stdout must NOT be our
  # terminal — otherwise it flips to interactive and takes over the tty instead
  # of writing the capture. Give it a sink (and close stdin); the rendered
  # escape codes would garble the terminal anyway.
  def self.capture_exec(bin : String, dests : Array(String), env : Process::Env) : Bool
    echo_cmd bin, [] of String, env
    status = Process.run(bin, env: env,
      input: Process::Redirect::Close, output: IO::Memory.new, error: IO::Memory.new)
    File.delete(bin) rescue nil
    File.delete("#{bin}.dwarf") rescue nil
    status.success? && dests.all? { |d| File.exists?(d) }
  end

  # Determine the requested output set, then (re)capture every stale program:
  # all compiles first, in parallel, then every run strictly one at a time.
  # The default (no scope flag) is all three outputs, one run each.
  # Returns whether every program captured without error.
  def self.capture(progs : Array(String), opts : Options) : Bool
    explicit = opts.shot || opts.anim || opts.dump || opts.all
    want_shot = opts.shot || opts.all || !explicit
    want_anim = opts.anim || opts.all || !explicit
    want_dump = opts.dump || opts.all || !explicit

    jobs = [] of {String, Array(String), Process::Env}
    progs.each do |prog|
      env = {} of String => String
      dests = [] of String
      if want_shot && !skip_output?(shot = shot_for(prog), prog, opts.force)
        env["CRYSTERM_SHOT"] = shot
        dests << shot
      end
      if want_dump && !skip_output?(dump = dump_for(prog), prog, opts.force)
        env["CRYSTERM_DUMP"] = dump
        dests << dump
      end
      if want_anim && !skip_output?(anim = anim_for(prog, opts.duration), prog, opts.force)
        env["CRYSTERM_ANIM"] = anim
        env["CRYSTERM_ANIM_SECS"] = opts.duration.to_s
        dests << anim
      end
      jobs << {prog, dests, env} unless dests.empty?
    end

    # Phase 1: compile everything in parallel — compiles have no realtime
    # component, so they can use every core.
    all_ok = true
    built = [] of {Array(String), Process::Env, String}
    parallel_each(jobs, opts.jobs) do |(prog, dests, env)|
      if bin = capture_build(prog)
        built << {dests, env, bin}
      else
        all_ok = false
      end
    end

    # Phase 2: run the binaries ONE AT A TIME, after all compiling is done. A
    # capture run is a real-time recording: the program's own timers and the
    # 10 fps sampling clock are both wall-clock-driven, and the capture is a
    # fixed-length filmstrip. Anything competing for CPU (another run, a
    # compile, ffmpeg encoders) delays the app's ticks; dropped ticks freeze
    # the scene, so the clip keeps its 5 s length but the content stutters and
    # leaps — scripted beats (typing, menus) visibly go missing. Serial runs
    # trade wall time (~6 s per program) for guaranteed fidelity.
    built.each do |(dests, env, bin)|
      all_ok = false unless capture_exec(bin, dests, env)
    end
    all_ok
  end

  # Compile every stale program next to its source (build-health check).
  # Returns whether every program built without error.
  def self.build(progs : Array(String), opts : Options) : Bool
    jobs = [] of {String, String}
    progs.each do |prog|
      bin = bin_for(prog)
      jobs << {prog, bin} unless skip_output?(bin, prog, opts.force)
    end

    all_ok = true
    parallel_each(jobs, opts.jobs) do |(prog, bin)|
      all_ok = false unless build_example(prog, bin, opts.release)
    end
    all_ok
  end

  # Print `git status` for *roots* and return whether they are clean (no new or
  # changed files). Used by --test to verify a regen reproduced the captures
  # in git, byte for byte.
  # Whether the captured paths are unchanged in git. *roots* are the named
  # targets, so an entry may be a directory or a single `.cr` program; `git
  # status -- <path>` takes either. A named program narrows the check to its own
  # directory's worth of pathspec, which is the point of naming it.
  def self.git_check(roots : Array(String)) : Bool
    rels = roots.map { |r| relative_to_root(File.expand_path(r)) }
    echo_cmd "git", ["status", "--"] + rels
    Process.run("git", ["status", "--"] + rels, output: STDOUT, error: STDERR, chdir: ROOT)
    porcelain = IO::Memory.new
    echo_cmd "git", ["status", "--porcelain", "--"] + rels
    Process.run("git", ["status", "--porcelain", "--"] + rels, output: porcelain, error: STDERR, chdir: ROOT)
    porcelain.to_s.strip.empty?
  end

  # ---- main -----------------------------------------------------------------

  def self.run(argv : Array(String))
    opts = parse_options(argv)

    # With no action flag and no named target, the default is the FULL
    # pipeline — (re)capture stale outputs, refresh the doc-comment screenshots,
    # then build the docs — so a bare `crystal run tools/test.cr` does all the
    # main features at once. Any explicit action flag (--shot/--anim/--dump/
    # --all/--build/--release/--doc-comments/--docs/--copy/--list/--test), or a
    # named target — a directory or a single `.cr` program, either of which
    # scopes capture — narrows the run to just that step. --force/--duration/
    # --jobs are modifiers, not selectors, so they keep the full pipeline.
    full = opts.targets.empty? &&
           !(opts.shot || opts.anim || opts.dump || opts.all ||
             opts.build || opts.release || opts.doc_comments ||
             opts.docs || opts.copy || opts.list || opts.test)

    roots = opts.targets.empty? ? DEFAULT_DIRS : opts.targets

    # Validated before any step reads them, so a typo'd path fails by name
    # rather than as an empty program list (which `--list` would happily print).
    if (bad = unusable_targets(roots)).any?
      STDERR.puts "not a directory or .cr program: #{bad.join(", ")}"
      exit 1
    end

    if opts.list
      progs = discover_programs(roots)
      puts "#{progs.size} program(s):"
      progs.each { |p| puts "  #{relative_to_root(p)}" }
      return
    end

    ok = true

    # ---- capture / build: default, the capture-scope flags, --build/--release,
    # a named target, or --test all (re)produce the captures.
    if full || opts.shot || opts.anim || opts.dump || opts.all ||
       opts.build || opts.release || opts.test || !opts.targets.empty?
      progs = discover_programs(roots)
      if progs.empty?
        STDERR.puts "no programs found (looked for <dir>/<dir>.cr, or any .cr, under: " \
                    "#{roots.map { |r| relative_to_root(File.expand_path(r)) }.join(", ")})"
        exit 1
      end
      ok = (opts.build ? build(progs, opts) : capture(progs, opts)) && ok

      # --test: after (re)producing missing outputs, the named paths must be
      # byte-identical to what's committed. A failed run or any git change fails.
      if opts.test
        ok = git_check(roots) && ok
        exit(ok ? 0 : 1)
      end
    end

    # ---- doc comments (operates on the registered widgets/layouts) ----
    maintain_doc_comments(discover) if full || opts.doc_comments

    # ---- docs build / asset copy ----
    if opts.copy
      copy_docs_assets
    elsif full || opts.docs
      build_docs
    end

    exit 1 unless ok
  end
end

WidgetExamples.run(ARGV)
