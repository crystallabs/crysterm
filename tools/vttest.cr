#!/usr/bin/env crystal
#
# vttest.cr — drive Paul Williams' `vttest` conformance suite through Crysterm's
# `TerminalEmulator`, headlessly, and dump the resulting grid for inspection.
#
# `vttest` is the standard VT100/VT220/xterm correctness tester. It draws a test
# pattern, prints on-screen what the pattern *should* look like ("there should
# be a frame of E's around this text"), and waits for RETURN. That on-screen
# description is the oracle: run a test, read the dump, check it matches. Any
# divergence is an emulator bug.
#
# This tool spawns `vttest` in a PTY, pipes its output straight into a fresh
# `TerminalEmulator` (no `Window`/render pipeline — the emulator is self-
# contained), wires the emulator's DA/cursor-position replies back to the PTY
# (vttest blocks on them), then steps through each test's screens by watching
# the grid for vttest's "Push <RETURN>" prompt and dumping between steps.
#
# Requires `vttest` on PATH (`brew install vttest`, `apt install vttest`, …).
#
# Usage:
#   crystal run tools/vttest.cr -- [options] TEST [TEST ...]
#
#     TEST            menu path(s) to run. A leaf test is just its main-menu
#                     number (`1`, `2`, `8`); a test behind a sub-menu is a
#                     dot-path (`6.3` = main-menu 6 → sub-menu 3, `9.7`, `10.1`).
#                     Default: 1.
#     --out DIR       where to write dumps (default: tools/vttest-out).
#     --screens N     max "Push RETURN" screens to step through per test (12).
#     --cols N        terminal width  (default 80).
#     --rows N        terminal height (default 24).
#     --dump          drive vttest through a real `Widget::Terminal` in a headless
#                     `Window` and write `Window#dump` (`screen-NN.dump`) — a grid
#                     PLUS an `attrs:` section listing per-run `fg/bg+flags`, so
#                     COLOUR and style tests (menu 11.6 &c.) can be verified, not
#                     just layout. Exercises the full emulator→widget→window path.
#
#   Default (text) mode writes DIR/test-<path>/screen-00.txt … (the grid plus a
#   trailing `cursor: (x,y)` line) and DIR/test-<path>/raw.bin (the exact bytes
#   vttest emitted, for decoding a suspect sequence). `--dump` mode writes
#   DIR/test-<path>/screen-00.dump … (grid + colour/attribute runs) instead.
#
# Note: some tests need live input (5 = keyboard, parts of 6 = reports) and will
# stall waiting for a keystroke; the per-screen timeout keeps the tool moving.
#
# CONTROLLING TERMINAL: vttest puts the tty in raw mode, so it needs to *own* a
# controlling terminal. On Linux, Crysterm's `Pty` runs the child through
# `setsid -c`, which grants one — vttest is spawned directly. macOS has no
# `setsid`, so we spawn it under `script`, which allocates a controlling tty and
# relays transparently.

require "../src/crysterm"

include Crysterm

module VtDriver
  extend self

  # ── options ──────────────────────────────────────────────────────────────
  out_dir = "tools/vttest-out"
  max_screens = 12
  cols = 80
  rows = 24
  render = false
  tests = [] of String

  args = ARGV.dup
  i = 0
  while i < args.size
    case args[i]
    when "--out"     then out_dir = args[i += 1]
    when "--screens" then max_screens = args[i += 1].to_i
    when "--cols"    then cols = args[i += 1].to_i
    when "--rows"    then rows = args[i += 1].to_i
    when "--dump"    then render = true
    when "-h", "--help"
      puts File.read(__FILE__).lines.take_while(&.starts_with?("#")).join('\n')
      exit 0
    else
      tests << args[i]
    end
    i += 1
  end
  tests = ["1"] if tests.empty?

  unless Process.find_executable("vttest")
    STDERR.puts "vttest not found on PATH — install it (brew install vttest / apt install vttest)."
    exit 1
  end

  DEFAULT_ATTR = Attr.pack(0, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT)

  # Spawns vttest with a controlling terminal (see file header). Returns a Pty.
  def self.spawn_vttest(cols, rows) : Pty
    env = {"TERM" => "vt100"}
    if Process.find_executable("setsid")
      Pty.new("vttest", [] of String, cols: cols, rows: rows, env: env)
    else
      # macOS `script`: `script [-q] file command ...`.
      Pty.new("script", ["-q", "/dev/null", "vttest"], cols: cols, rows: rows, env: env)
    end
  end

  # One grid row as text: drop wide-glyph continuation NULs, keep spaces (they
  # carry the cursor-movement geometry these tests exercise), strip the right.
  def self.row_text(emu, y) : String
    emu.lines[emu.ydisp + y].map(&.char).reject { |ch| ch.ord == 0 }.join.rstrip
  end

  # The whole viewport as one blob (unstripped) — for prompt detection.
  def self.blob(emu, rows) : String
    String.build do |io|
      rows.times { |y| io << emu.lines[emu.ydisp + y].map(&.char).reject { |c| c.ord == 0 }.join << '\n' }
    end
  end

  def self.dump(emu, rows) : String
    String.build do |io|
      rows.times { |y| io << row_text(emu, y) << '\n' }
      io << "cursor: (#{emu.cursor_x},#{emu.cursor_y})\n"
    end
  end

  # Blocks (yielding to the reader fiber) until `needle` is on-screen or the
  # timeout elapses. Returns whether it was found.
  def self.wait_for(emu, rows, needle, timeout) : Bool
    deadline = Time.instant + timeout
    loop do
      return true if blob(emu, rows).includes?(needle)
      return false if Time.instant > deadline
      sleep 20.milliseconds
    end
  end

  # Waits for a *new* prompt: a screen different from `prev` that shows either a
  # "Push <RETURN>" prompt or the (sub)menu, then waits for it to *settle* before
  # returning. Two guards matter for report tests:
  #
  #   * only a *changed* screen counts, so we press RETURN once per prompt, never
  #     twice while the previous frame's "Push" text still lingers;
  #   * we wait until the screen stops changing (STABLE_MS) before returning, so
  #     the RETURN we send next can't land while vttest is still reading a report
  #     it solicited right after printing the prompt (DSR after "Push", as in the
  #     alt-screen cursor save/restore tests) — that read would otherwise capture
  #     our injected CR as "…R\r" and reject an otherwise-correct reply.
  STABLE_MS = 150

  def self.wait_for_change(emu, rows, prev, timeout) : String?
    deadline = Time.instant + timeout
    loop do
      b = blob(emu, rows)
      break if b != prev && (b.includes?("Push") || b.includes?("Enter choice number"))
      return nil if Time.instant > deadline
      sleep 20.milliseconds
    end
    # Settle: return only once the screen has held steady for STABLE_MS.
    last = blob(emu, rows)
    steady = Time.instant
    loop do
      sleep 30.milliseconds
      b = blob(emu, rows)
      if b == last
        return b if (Time.instant - steady).total_milliseconds >= STABLE_MS
      else
        last = b
        steady = Time.instant
      end
    end
  end

  # ── shared driving loop ───────────────────────────────────────────────────
  # Walks the menu path, then steps through the leaf test's screens, snapshotting
  # each. Back-end-agnostic: `emu` is read for prompt detection (same in both
  # modes), while `send`/`eof`/`snapshot` are closures the caller wires to either
  # a bare PTY or the widget. Returns the number of screens captured.
  def self.drive(path, dir, keys, max_screens, rows, emu,
                 send : String ->, eof : -> Bool, snapshot : String, TerminalEmulator ->) : Int32
    unless wait_for(emu, rows, "Enter choice number", 5.seconds)
      STDERR.puts "test #{path}: main menu never appeared"
      return 0
    end

    # Walk the menu path. Every key but the last should land on another menu
    # ("Enter choice number"); the last drops us into the actual test.
    keys.each_with_index do |k, idx|
      send.call "#{k}\r"
      sleep 200.milliseconds
      wait_for(emu, rows, "Enter choice number", 2.seconds) if idx < keys.size - 1
    end

    screens = 0
    prev = ""
    max_screens.times do |n|
      cur = wait_for_change(emu, rows, prev, 2.seconds)
      break unless cur                              # timed out with no new prompt
      break if cur.includes?("Enter choice number") # back at a (sub)menu ⇒ done
      snapshot.call(File.join(dir, "screen-#{n.to_s.rjust(2, '0')}"), emu)
      screens += 1
      break if eof.call
      prev = cur
      send.call "\r"
      sleep 100.milliseconds
    end

    # Climb back out: one "0" per menu level returns to the parent, the last to
    # the shell — vttest then exits.
    keys.size.times do
      send.call "0\r" rescue nil
      sleep 80.milliseconds
    end
    screens
  end

  # ── text mode: bare emulator + PTY ────────────────────────────────────────
  def self.run_emu(path, dir, keys, max_screens, cols, rows)
    emu = TerminalEmulator.new(cols, rows, DEFAULT_ATTR)
    pty = spawn_vttest(cols, rows)
    emu.output = pty.master
    raw = File.new(File.join(dir, "raw.bin"), "w")
    eof = false
    spawn do
      buf = Bytes.new(4096)
      loop do
        n = pty.master.read buf
        break (eof = true) if n == 0
        raw.write buf[0, n]
        raw.flush
        emu.feed buf[0, n]
      rescue
        eof = true
        break
      end
    end
    n = drive(path, dir, keys, max_screens, rows, emu,
      ->(s : String) { pty.write s },
      -> { eof },
      ->(base : String, e : TerminalEmulator) { File.write("#{base}.txt", dump(e, rows)) })
    raw.close
    pty.kill
    n
  end

  # ── dump mode: real Widget::Terminal in a headless Window ──────────────────
  # Renders vttest through the full emulator→widget→window pipeline so
  # `Window#dump` can report per-cell colour/attributes, not just characters.
  def self.run_widget(path, dir, keys, max_screens, cols, rows)
    window = Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: cols, height: rows, force_unicode: true)
    term = Widget::Terminal.new(
      parent: window, top: 0, left: 0, width: "100%", height: "100%",
      shell: spawn_shell, args: spawn_args, env: {"TERM" => "vt100"})
    eof = false
    term.on(::Crysterm::Event::ProcessExited) { eof = true }
    window.repaint # first render bootstraps the widget: spawns vttest, starts its reader fiber
    emu = term.emulator
    unless emu
      STDERR.puts "test #{path}: widget failed to bootstrap"
      return 0
    end
    n = drive(path, dir, keys, max_screens, rows, emu,
      ->(s : String) { term.pty.try(&.write(s)); nil },
      -> { eof },
      ->(base : String, _e : TerminalEmulator) { window.repaint; File.write("#{base}.dump", window.dump) })
    term.kill rescue nil
    n
  end

  # vttest command split into (shell, args) for the widget path, mirroring
  # `spawn_vttest`'s controlling-terminal handling.
  def self.spawn_shell : String
    Process.find_executable("setsid") ? "vttest" : "script"
  end

  def self.spawn_args : Array(String)
    Process.find_executable("setsid") ? [] of String : ["-q", "/dev/null", "vttest"]
  end

  # ── run one test ──────────────────────────────────────────────────────────
  # `path` is a dot-separated menu path: "1" (a leaf), "6.3" (main 6 → sub 3).
  def self.run_test(path, out_dir, max_screens, cols, rows, render)
    keys = path.split('.')
    dir = File.join(out_dir, "test-#{path}")
    Dir.mkdir_p dir
    n = render ? run_widget(path, dir, keys, max_screens, cols, rows) : run_emu(path, dir, keys, max_screens, cols, rows)
    STDERR.puts "test #{path}: captured #{n} screen(s) -> #{dir}"
    Fiber.yield
  end

  tests.each { |t| run_test(t, out_dir, max_screens, cols, rows, render) }
  puts "dumps in #{out_dir}/"
end
