module Crysterm
  # The shortcut-dispatch engine of `Action` (mirroring Qt's `QShortcutMap`):
  # the shared per-window arbiter that matches every installed action's key
  # sequences together, drives multi-keystroke chords, and gates firing on
  # context/focus. The `Action` data model itself (properties, activation,
  # menus) lives in `action.cr`; this file holds only the accelerator state
  # machine. (Not named `action_shortcuts.cr` — that name belongs to
  # `src/mixin/action_shortcuts.cr`, the widget-side `key ... do` DSL.)
  class Action
    # Shared per-window shortcut dispatch state (mirroring Qt's `QShortcutMap`):
    # every action installed on a window, the window's single half-entered chord
    # prefix, and the one window-level `KeyPress` subscription feeding them all.
    # One shared arbiter — rather than one handler per action — so that a chord
    # in progress consumes its completing stroke ahead of any other action's
    # fresh single-stroke match, and so that a key consumed elsewhere still
    # clears the prefix. See `Action.dispatch_shortcut`.
    private class ShortcutMap
      # Installed actions, in installation order (which breaks ties between
      # identical sequences: the earlier-installed action fires).
      getter actions = [] of Action

      # The half-entered chord: leading keystrokes typed so far toward one or
      # more multi-stroke shortcuts. Empty between chords.
      property pending : KeySequence = KeySequence.new

      # Reusable buffer for the candidate sequence built on every keypress by
      # `Action.dispatch_shortcut`/`.advance_shortcut`, so matching a shortcut
      # allocates nothing per keystroke. Distinct from `#pending` — `pending`
      # is only ever updated by copying this buffer's contents into it, never
      # by aliasing it, so reusing it across calls is safe.
      getter scratch = KeySequence.new

      # The one window-level `KeyPress` subscription driving
      # `Action.dispatch_shortcut` for this window.
      getter subscription = ::Crysterm::Subscription.new
    end

    # The shared per-window shortcut arbiters: created on the first
    # `#install_shortcut` for a window, dropped again when its last action is
    # uninstalled.
    @@shortcut_maps = {} of ::Crysterm::Window => ShortcutMap

    # Installs a window-level accelerator so this action fires when its shortcut
    # is pressed. *host* is the widget the action is presented in, used to gate
    # `Widget`-context shortcuts on focus. Idempotent per window; no-op without
    # a shortcut.
    #
    # All actions installed on a window share one `ShortcutMap` (a single
    # window-level `KeyPress` handler), so their sequences are matched together
    # — see `Action.dispatch_shortcut`.
    def install_shortcut(window : ::Crysterm::Window, host : Widget? = nil) : Nil
      if host
        @shortcut_host_by_window[window] = host
      else
        @shortcut_host_by_window.delete window
      end
      return if @shortcuts.empty?
      return unless @shortcut_windows.add? window
      map = @@shortcut_maps[window]? || begin
        m = @@shortcut_maps[window] = ShortcutMap.new
        m.subscription.on(window, ::Crysterm::Event::KeyPress) do |e|
          Action.dispatch_shortcut window, e
        end
        m
      end
      map.actions << self
    end

    # Removes this action from the shared accelerator installed by
    # `#install_shortcut` for *window*. A half-entered chord prefix is dropped
    # unless a still-installed action can still complete it; the shared
    # `KeyPress` handler itself goes away with the window's last action.
    def uninstall_shortcut(window : ::Crysterm::Window) : Nil
      @shortcut_host_by_window.delete window
      return unless @shortcut_windows.delete window
      map = @@shortcut_maps[window]? || return
      map.actions.delete self
      unless map.pending.empty? || map.actions.any?(&.shortcut_continues?(map.pending))
        map.pending.clear
      end
      if map.actions.empty?
        map.subscription.off
        @@shortcut_maps.delete window
      end
    end

    # Feeds keypress *e* (on *window*) through the window's shared shortcut
    # state machine, supporting multi-keystroke chords (Qt's `QKeySequence`,
    # e.g. "Ctrl+K, Ctrl+B"). A single-stroke shortcut fires immediately; a
    # chord advances the window's pending prefix and fires only once fully
    # entered.
    #
    # The window's actions are matched *together* (Qt's `QShortcutMap`):
    # while a chord is in progress, its next stroke is first tried as a chord
    # continuation across every installed sequence, so another action's fresh
    # single-stroke match cannot steal it (a Ctrl+S action does not preempt the
    # Ctrl+S completing Ctrl+K, Ctrl+S). A stroke that instead breaks the chord
    # drops the prefix and is re-tried as a fresh first stroke, not swallowed.
    #
    # A key that neither extends the prefix nor begins a fresh shortcut clears
    # it (no inter-stroke timeout) — and so does a key already `accept`ed by an
    # earlier handler (the focused widget's key walk, `KeyShortcuts`, …), which
    # can only ever clear, never fire. A consumed key is `accept`ed so it
    # doesn't also reach the focused widget.
    protected def self.dispatch_shortcut(window : ::Crysterm::Window, e : ::Crysterm::Event::KeyPress) : Nil
      map = @@shortcut_maps[window]? || return
      if e.accepted?
        map.pending.clear
        return
      end
      k = e.key
      unless k
        # A plain character (no named `#key`): typing text between a chord's
        # strokes must not leave the prefix live.
        map.pending.clear
        return
      end
      s = map.scratch
      unless map.pending.empty?
        # A chord in progress owns the stroke: try it as a continuation first.
        s.clear
        s.concat map.pending
        s << k
        return if advance_shortcut(window, map, e, s)
        # The stroke broke the chord: drop the prefix and re-try the same
        # stroke as a fresh first stroke below.
        map.pending.clear
      end
      s.clear
      s << k
      advance_shortcut window, map, e, s
    end

    # Matches *candidate* (the strokes entered so far) against every installed
    # action's sequences at once: an exact match fires the first action (in
    # installation order) whose gates pass — an exact match deliberately beats a
    # proper-prefix hold when one action's full sequence is another's chord
    # prefix (Qt's behavior: `[CtrlS]` fires even while `[CtrlS, CtrlX]` is also
    # registered). Otherwise a proper prefix of any passing action holds
    # *candidate* as the window's pending chord. Returns whether *candidate*
    # engaged a shortcut; when it did, the event is `accept`ed.
    private def self.advance_shortcut(window : ::Crysterm::Window, map : ShortcutMap, e : ::Crysterm::Event::KeyPress, candidate : KeySequence) : Bool
      holds = false
      map.actions.each do |a|
        exact, prefix = a.shortcut_candidate window, e, candidate
        if exact
          map.pending.clear
          e.accept
          a.trigger
          return true
        end
        holds ||= prefix
      end
      if holds
        map.pending.clear
        map.pending.concat candidate # a proper prefix — await the rest
        e.accept
      end
      holds
    end

    # How *candidate* (the strokes entered so far) relates to this action's
    # shortcut list right now: `{exact, prefix}` — whether it exactly matches a
    # sequence, and whether it is a proper prefix of a longer one. Both are
    # `false` whenever the action may not fire at all: disabled, a dropped
    # auto-repeat, or out of its focus context. The (possibly focus-walking)
    # `#shortcut_active?` probe runs only after a cheap key-list match, so
    # irrelevant keys skip it.
    protected def shortcut_candidate(window : ::Crysterm::Window, e : ::Crysterm::Event::KeyPress, candidate : KeySequence) : {Bool, Bool}
      none = {false, false}
      exact = false
      prefix = false
      @shortcuts.each do |seq|
        next unless shortcut_prefix? seq, candidate
        if seq.size == candidate.size
          exact = true
        else
          prefix = true
        end
      end
      return none unless exact || prefix
      return none if (e.repeat? && !auto_repeat?) || !enabled?
      return none unless shortcut_active? window
      {exact, prefix}
    end

    # Whether *candidate* is a proper prefix of one of this action's sequences —
    # a chord in progress that further strokes could still complete.
    protected def shortcut_continues?(candidate : KeySequence) : Bool
      @shortcuts.any? { |seq| seq.size > candidate.size && shortcut_prefix?(seq, candidate) }
    end

    # Whether *candidate* is a leading prefix of *seq* (equal length counts).
    private def shortcut_prefix?(seq : KeySequence, candidate : KeySequence) : Bool
      return false if candidate.size > seq.size
      candidate.each_with_index { |k, i| return false unless seq[i] == k }
      true
    end

    # Whether the shortcut may fire given `#shortcut_context` and current focus.
    # `Window`/`Application` always fire; `Widget` requires a host widget to
    # hold focus; `WidgetWithChildren` also accepts focus on a host's descendant.
    private def shortcut_active?(window : ::Crysterm::Window) : Bool
      case shortcut_context
      in ShortcutContext::Application, ShortcutContext::Window
        true
      in ShortcutContext::Widget
        host_focused?(window, &.focused?)
      in ShortcutContext::WidgetWithChildren
        host_focused?(window) { |h| h.focused? || descendant_focused?(h) }
      end
    end

    # Whether any gating host of a `Widget`-context shortcut on *window* satisfies
    # the block. The gating hosts are this action's associated widgets living on
    # *window* (one focused on another window must not fire the shortcut), falling
    # back to the host recorded at `#install_shortcut` time when none is.
    # Evaluates in place — this runs on every keypress per Widget-context action.
    private def host_focused?(window : ::Crysterm::Window, & : Widget -> Bool) : Bool
      any_on_window = false
      @associated_widgets.each do |w|
        next unless w.window? == window
        any_on_window = true
        return true if yield w
      end
      # Fall back to the install-time host only when no associated widget is on this window.
      return false if any_on_window
      (h = @shortcut_host_by_window[window]?) ? (yield h) : false
    end

    # Whether the focused widget of *host*'s window is *host* itself or a
    # descendant of it (for `WidgetWithChildren` context).
    private def descendant_focused?(host : Widget) : Bool
      f = host.window?.try &.focused
      while f
        return true if f == host
        f = f.parent
      end
      false
    end
  end
end
