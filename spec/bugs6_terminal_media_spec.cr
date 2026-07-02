require "./spec_helper"

include Crysterm

# Regression specs for BUGS6 section 7 (Terminal handshake / launchers / media).
#
# BUG 1 — In-band graphics / external-overlay media backends must be
#   constructible *detached* (no explicit parent) without raising.
#   The bug report expected a `NilAssertionError` from the raising `window`
#   accessor used to register the render/overlay listeners. In practice this
#   does NOT reproduce: `Widget#initialize` runs
#   `@window ||= determine_window unless window?` (widget.cr), and
#   `determine_window` → `Window.global` (`instances[-1]? || new`) always yields
#   a non-nil window, so by the time the media constructors reach
#   `register_overlay_listeners window` / `register_render_hook(window)` the
#   `window` accessor never raises. These specs pin that guarantee: a
#   parentless media widget constructs without raising and lands on the global
#   window. (See the report note flagging BUG 1 as not-present.)
# BUG 2 — Terminal.find_launcher's generic fallback must build the launcher
#   from the *resolved* spec (the literal, possibly absolute, name) rather than
#   the basename, so Process.new execs the exact validated path instead of
#   PATH-resolving the basename.
# BUG 3 — Terminal.accept_with_timeout must not leak a socket accepted in the
#   timeout race. Documented below (not runtime-asserted; see the note).

private def headless_window(w = 12, h = 4)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

# --------------------------------------------------------------------------
# BUG 1: detached construction of window-owns-pixels media backends
# --------------------------------------------------------------------------

describe "Media backends detached construction (BUGS6)" do
  it "constructs in-band graphics backends without a parent (no raise)" do
    # A headless window created first becomes the most-recent instance, so the
    # global-window fallback attaches these parentless widgets to it (rather
    # than spawning a real terminal window during the spec).
    s = headless_window

    sixel = Widget::Media::Sixel.new file: "pic.png", width: 4, height: 3
    kitty = Widget::Media::Kitty.new file: "pic.png", width: 4, height: 3
    regis = Widget::Media::Regis.new file: "pic.png", width: 4, height: 3
    iterm = Widget::Media::Iterm.new file: "pic.png", width: 4, height: 3

    # Construction returned without raising and the widgets resolved a window
    # (the global-window fallback), which is why `register_overlay_listeners
    # window` did not hit the raising accessor.
    sixel.window?.should eq s
    kitty.window?.should eq s
    regis.window?.should eq s
    iterm.window?.should eq s
  ensure
    s.try &.destroy
  end

  it "constructs Tek, Ueberzug and Overlay backends without a parent (no raise)" do
    s = headless_window

    tek = Widget::Media::Tek.new file: "pic.png", width: 4, height: 3
    uz = Widget::Media::Ueberzug.new file: "pic.png", width: 4, height: 3
    ov = Widget::Media::Overlay.new file: "pic.png", width: 4, height: 3

    tek.window?.should eq s
    uz.window?.should eq s
    ov.window?.should eq s
  ensure
    s.try &.destroy
  end

  it "renders a graphics backend attached to a window without raising" do
    s = headless_window
    img = Widget::Media::Sixel.new parent: s, width: 4, height: 3
    img.window?.should eq s
    s._render # exercises the registered Rendered listener (empty image: no-op)
  ensure
    s.try &.destroy
  end
end

# --------------------------------------------------------------------------
# BUG 2: find_launcher generic fallback uses the resolved (literal) path
# --------------------------------------------------------------------------

describe "Terminal.resolve_launcher generic fallback path (BUGS6)" do
  it "builds the fallback launcher from the literal absolute path, not the basename" do
    # `/bin/sh` exists on macOS and Linux, and "sh" is not a registered
    # backend, so resolution falls through to the generic `<name> -e` fallback.
    launcher = Crysterm::Terminal.resolve_launcher("/bin/sh")
    launcher.should_not be_nil
    # BUG 2: the launcher's argv[0] (its name) must be the literal path passed
    # in, so Process.new execs "/bin/sh" rather than PATH-resolving "sh".
    launcher.not_nil!.name.should eq "/bin/sh"
  end

  it "returns nil for an absolute path that neither exists nor names a known backend" do
    Crysterm::Terminal.resolve_launcher("/opt/nope/crysterm-no-such-terminal-xyz").should be_nil
  end
end

# --------------------------------------------------------------------------
# BUG 3: accept_with_timeout socket leak on the timeout race
# --------------------------------------------------------------------------
#
# The fix drains and closes any socket the accept fiber sends *after* the
# select timeout fires (`spawn { ch.receive?.try &.close }`), so a connection
# that lands in the capacity-1 channel between the timeout and the caller's
# `server.close` no longer leaks its UNIXSocket / fd for the process lifetime.
#
# No dedicated runtime assertion is provided here, deliberately:
#   * `accept_with_timeout` is a `private def self.` on `Terminal`, so it can't
#     be invoked from a spec, and its only caller (`spawn_window`) needs a real
#     terminal emulator to complete.
#   * Triggering the timeout branch would mean waiting out `HANDSHAKE_TIMEOUT`
#     (15s), and proving the fd is actually closed afterwards would require
#     inspecting the process fd table.
# FLAG: the fix is verified by compilation/inspection only; no feasible
# headless runtime assertion. (Mirrors the BUGS5 BUG 4 rationale.)
pending "Terminal.accept_with_timeout drains a late socket on timeout (doc-only, BUGS6)"
