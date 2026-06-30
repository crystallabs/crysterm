#!/usr/bin/env crystal
#
# test.cr — (re)produce the captures for Crysterm example programs.
#
# Point it at one or more directories. It walks each recursively and, in every
# directory at or below a root, picks the programs to run:
#
#   * if the dir has a file of the same name (`foo/foo.cr`), that is THE program
#     and the dir's other `.cr` files are treated as its support code (untouched);
#   * otherwise every `.cr` directly in the dir is its own program.
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
# left alone when it is newer than its `.cr`, unless --force.
#
# Separately, `--doc-comments` embeds each widget's capture in its API docs by
# maintaining a fenced block in the source class doc comment, and `--docs` runs
# `crystal docs` then copies `examples/` into the docs tree.
#
# Usage: crystal run tools/test.cr -- [options] [dir ...]   (default: examples tests)

require "file_utils"

module WidgetExamples
  VERSION = "0.1.0"

  ROOT       = File.expand_path(File.join(__DIR__, ".."))
  WIDGETS_CR = File.join(ROOT, "src", "widgets.cr")

  # Directories captured when none are named on the command line.
  DEFAULT_DIRS = [File.join(ROOT, "examples"), File.join(ROOT, "tests")]

  # ---- program discovery ----------------------------------------------------

  # Every program found by walking *roots* recursively. In each directory at or
  # below a root: if there is a file of the same name (`foo/foo.cr`), that is the
  # program and the dir's other `.cr` files are treated as its support code and
  # left alone; otherwise every `.cr` directly in the dir is its own program (the
  # shared `example.cr` harness excepted). Sorted and de-duped.
  def self.discover_programs(roots : Array(String)) : Array(String)
    progs = [] of String
    roots.each do |root|
      abs = File.expand_path(root)
      next unless Dir.exists?(abs)
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
    out_dir : String, # output dir, e.g. <root>/examples/widget
    base_ns : String  # "Crysterm::Widget" / "Crysterm::Layout"

  KINDS = [
    Kind.new("widget", File.join(ROOT, "src", "widget"), File.join(ROOT, "examples", "widget"), "Crysterm::Widget"),
    Kind.new("layout", File.join(ROOT, "src", "layout"), File.join(ROOT, "examples", "layout"), "Crysterm::Layout"),
  ]

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

  # ---- doc-comment maintenance ----------------------------------------------
  #
  # Each widget's API docs (via `crystal docs`) get its screenshot embedded by a
  # managed block inside the *class doc comment* of its source file. The block is
  # fenced by HTML comments (invisible in the rendered Markdown) so the tool can
  # find, refresh, or migrate it without disturbing hand-written prose:
  #
  #     # <!-- widget-examples:capture v1 -->
  #     # ![Button screenshot](../../examples/widget/button/button.png)
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
  # the animation (`<stem>.<secs>s.apng`, which browsers play inline) and falls
  # back to the still (`<stem>.png`) when there is no APNG. One entry per example
  # program file that has a capture.
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
    echo_cmd "crystal", ["docs"]
    status = Process.run("crystal", ["docs"], output: STDOUT, error: STDERR, chdir: ROOT)
    exit 1 unless status.success?
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
    property dirs = [] of String
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
        o.dirs << arg
      end
      i += 1
    end
    o
  end

  HELP = <<-TXT
    test.cr v#{VERSION} — (re)produce captures for example programs.

    Usage: crystal run tools/test.cr -- [options] [dir ...]

    For every directory at or below each DIR (default: examples tests): if it has
    a program of the same name (foo/foo.cr) that one runs (the dir's other .cr are
    its support code); otherwise each .cr in the dir runs on its own. Each program
    is compiled and run headlessly to (re)produce its captures beside it: foo.png,
    foo.<secs>s.apng and foo.dump. An output newer than its .cr is left alone
    unless --force.

      -f, --force       re-make outputs even when up to date
          --shot        only the still PNG
          --anim        only the APNG
          --dump        only the text golden (foo.dump)
          --all         all three (the default); combine the scope flags for a subset
          --duration N  animation length in seconds (default 5)
          --build       compile each program next to its source (foo/foo.cr -> foo/foo)
          --release     like --build, but an optimized (--release) build
      -j, --jobs N      capture/build concurrency (default #{default_jobs}; each is a compile)
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

  # Default concurrency. Each job is a full `crystal` compile (RAM heavy), so
  # stay under the core count; override with `--jobs`.
  def self.default_jobs : Int32
    Math.max(1, Math.min(8, System.cpu_count.to_i - 1))
  end

  # Run *work* over *items* with at most *jobs* fibers in flight. Each fiber's
  # `crystal` subprocess runs in parallel via the OS while the fibers themselves
  # stay cooperative (single-threaded), so shared counters need no locking.
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

  # Run *program* headlessly with *env* set, producing every file in *dests* in
  # ONE process. *env* holds whichever of `CRYSTERM_SHOT`/`CRYSTERM_DUMP`/
  # `CRYSTERM_ANIM` were requested; the harness emits all of them in a single run,
  # so the default costs one compile + one exec instead of one per output kind.
  #
  # We `crystal build` to a *unique* temp binary and then exec it, rather than
  # `crystal run` — because two programs that share a basename would race on
  # `crystal run`'s basename-derived temp executable under `--jobs`. The compile
  # cache stays shared/warm; only the output binary is per-job.
  #
  # The captured program self-renders only when it runs *headless*, which it
  # auto-detects from `STDOUT.tty?` (`Crysterm.interactive?`). So its stdout must
  # NOT be our terminal — otherwise it flips to interactive and takes over the
  # tty instead of writing the capture. We give it a sink (and close stdin); the
  # rendered escape codes would garble the terminal anyway.
  def self.capture_run(program : String, dests : Array(String), env : Process::Env) : Bool
    bin = File.tempname("crysterm-ex", "")
    build_args = ["build", "--no-color", program, "-o", bin]
    echo_cmd "crystal", build_args
    build = Process.run("crystal", build_args, output: STDOUT, error: STDERR, chdir: ROOT)
    return false unless build.success? && File.exists?(bin)
    echo_cmd bin, [] of String, env
    status = Process.run(bin, env: env,
      input: Process::Redirect::Close, output: IO::Memory.new, error: IO::Memory.new)
    File.delete(bin) rescue nil
    File.delete("#{bin}.dwarf") rescue nil
    status.success? && dests.all? { |d| File.exists?(d) }
  end

  # Determine the requested output set, then (re)capture every stale program in
  # parallel. The default (no scope flag) is all three outputs, one run each.
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

    all_ok = true
    parallel_each(jobs, opts.jobs) do |(prog, dests, env)|
      all_ok = false unless capture_run(prog, dests, env)
    end
    all_ok
  end

  # Compile every stale program next to its source (a build-health check).
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
  # already in git, byte for byte.
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

    # Standalone doc steps operate on the registered widgets/layouts, not on the
    # captured directories.
    if opts.doc_comments
      maintain_doc_comments(discover)
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

    roots = opts.dirs.empty? ? DEFAULT_DIRS : opts.dirs
    progs = discover_programs(roots)
    if progs.empty?
      STDERR.puts "no programs found (looked for <dir>/<dir>.cr under: " \
                  "#{roots.map { |r| relative_to_root(File.expand_path(r)) }.join(", ")})"
      exit 1
    end

    if opts.list
      puts "#{progs.size} program(s):"
      progs.each { |p| puts "  #{relative_to_root(p)}" }
      return
    end

    ok = opts.build ? build(progs, opts) : capture(progs, opts)

    # --test: after (re)producing missing outputs, the dirs must be byte-identical
    # to what's committed. A failed run or any git change fails the check.
    if opts.test
      ok = git_check(roots) && ok
      exit(ok ? 0 : 1)
    end
  end
end

WidgetExamples.run(ARGV)
