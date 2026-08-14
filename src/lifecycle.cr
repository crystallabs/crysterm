module Crysterm
  class GlobalEventHub
    include EventHandler
  end

  GlobalEvents = GlobalEventHub.new

  # Runs the shared pre-exit sequence, then terminates. Emits
  # `Event::AboutToQuit` on every live `Application` first — the "save your state
  # now" step a bare `exit` skips (≈ Qt's `QCoreApplication::aboutToQuit`) — then
  # exits, so the `at_exit` net still restores each terminal. The signal traps
  # below use this instead of a raw `exit`.
  #
  # Best-effort per app: a save-state handler that raises must not block the
  # terminal-restoring exit.
  def self.shutdown(status : Int32 = 0) : NoReturn
    Application.instances.dup.each { |app| app.emit(Event::AboutToQuit) rescue nil }
    exit status
  end

  # SIGINT (Ctrl+C) must be trapped: Crystal's default action terminates without
  # running `at_exit`, skipping the terminal-restore chain. Routing it through
  # `exit` (like TERM/QUIT) ensures cleanup runs. It matters during startup —
  # between `Window.new` (enters the alt buffer) and the input fiber establishing
  # raw mode, the tty is still cooked, so Ctrl+C arrives as a real SIGINT and
  # interrupting there would strand the terminal in the alt buffer. Once raw mode
  # is active ISIG is off, Ctrl+C is a keystroke, and this trap is dormant.
  Process.on_terminate do
    Crysterm.shutdown
  end
  Signal::QUIT.trap do
    Crysterm.shutdown
  end
  # NOTE No `Signal::KILL.trap`: SIGKILL (like SIGSTOP) is uncatchable — the
  # kernel never delivers it to a handler, so `sigaction` for it just fails
  # silently. `kill -9` unavoidably leaves the terminal unrestored.
  Signal::WINCH.trap do
    # XXX IIRC, urwid has an additional method of tracking resizes. Check it out and add
    # additional support here if necessary.
    GlobalEvents.emit Event::Resize
  end

  # Hands every connected window's terminal back before the process suspends:
  # leaves the alt buffer, turns off mouse reporting/keyboard protocol/paste and
  # restores cooked mode (`Tput#pause` stores a resume continuation). Without it,
  # a suspend leaves the shell prompt inside the app's alt buffer with pointer
  # motion spewing SGR sequences. Best-effort per window: a dead fd must not
  # block the rest.
  def self.suspend_terminals : Nil
    Window.instances.dup.each do |w|
      next unless w.connected?
      begin
        w.tput.pause
      rescue
      end
    end
  end

  # Restores every connected window's terminal after the process continues
  # (`SIGCONT`): re-enters the alt buffer/modes via the continuation `#pause`
  # stored, then reallocs (invalidating `@flushed_lines` — the terminal no longer shows
  # the pre-suspend frame, so diffing against it would leave shell output as
  # permanent corruption) and repaints.
  def self.resume_terminals : Nil
    Window.instances.dup.each do |w|
      next unless w.connected?
      begin
        w.tput.resume
        w.realloc
        w.update
      rescue
      end
    end
  end

  # SIGTSTP: suspend cleanly. TSTP (unlike SIGSTOP) is catchable, so restore
  # the terminal(s) first, then deliver the real (uncatchable) STOP to self.
  # On `fg`, the shell sends SIGCONT, handled below.
  Signal::TSTP.trap do
    suspend_terminals
    Process.signal Signal::STOP, Process.pid
  end
  Signal::CONT.trap do
    resume_terminals
  end

  at_exit do
    # Iterate a copy: `Window#destroy` calls `@@instances.delete self`, so
    # iterating the live registry in place shifts elements under the index-based
    # iterator and skips windows, leaving their terminal unrestored.
    Window.instances.dup.each &.destroy
  end
end
