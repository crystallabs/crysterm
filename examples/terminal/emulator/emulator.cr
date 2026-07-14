require "../../../src/crysterm"

# term — a minimal, real terminal emulator, the way xterm or kitty starts one.
#
# Opens a full-screen window, runs your shell (`$SHELL`, or a command given on
# the argv) inside a pseudo-terminal, and renders its live output. Everything a
# standalone terminal needs is wired here:
#
#   * the whole screen is the terminal (no border, no chrome);
#   * the widget is `.focus`ed, so every keystroke — including `q` and Ctrl-Q —
#     is forwarded to the child instead of being swallowed as a UI hotkey;
#   * `default_quit_keys: false` on the window disables Crysterm's app-level
#     `q`/Ctrl-Q quit, so those keys reach the shell too (you quit by exiting the
#     shell: `exit`, or Ctrl-D);
#   * the child's window-title reports (OSC 0/2) are mirrored onto the host
#     terminal's title;
#   * when the child process ends, the app exits with the child's status.
#
# This is the difference between the widget *demo* (tests/widget/terminal, which
# runs under the capture harness) and a program you'd actually use as a terminal.
#
# Usage:
#   crystal run examples/terminal/term/term.cr            # runs $SHELL
#   crystal run examples/terminal/term/term.cr -- htop    # runs a command
#   crystal run examples/terminal/term/term.cr -- vim x   # ...with arguments
module Crysterm
  include Tput::Namespace

  # Anything after the program name is the command to run instead of the shell;
  # the first token is the program, the rest its arguments. With no argv, the
  # Terminal falls back to `Config.input_shell` ($SHELL, else `sh`).
  shell = ARGV.first?
  args = ARGV.size > 1 ? ARGV[1..] : [] of String

  # `default_quit_keys: false` hands `q`/Ctrl-Q to the focused terminal rather
  # than treating them as "quit the app" (see Application#route_input). The only
  # way out is the child exiting — exactly how a real terminal behaves.
  window = Window.new(
    title: "crysterm — terminal",
    default_quit_keys: false,
  )

  # No coordinates, and no layout engine: the terminal *is* the window. A widget
  # with no `width`/`height` already resolves to its parent's whole interior, and
  # with no `left`/`top` it sits at the interior's origin — so `top: 0, left: 0,
  # width: "100%", height: "100%"` would just spell out the default. There's also
  # no layout to install: layouts exist to arrange siblings against each other,
  # and there's exactly one child here. Qt does the same — a widget with no
  # installed layout places its children by their own geometry (Layout::Manual),
  # which for a lone full-bleed child is precisely what's wanted.
  term = Widget::Terminal.new(
    parent: window,
    shell: shell, args: args,
  )

  # Mirror the child's title reports (OSC 0/2) onto the host window/terminal.
  term.on(::Crysterm::Event::SetContent) { window.title = term.title }

  # The child ended: leave with its exit status. `at_exit` (in crysterm.cr)
  # restores the terminal — cooks the tty, leaves the alt-screen — on the way
  # out, so there's nothing to clean up here.
  term.on(::Crysterm::Event::Exit) do |e|
    exit(e.code || 0)
  end

  term.focus
  window.exec
end
