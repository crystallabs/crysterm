class Tput
  class Features
    # Whether the terminal presents DEC 2026 synchronized updates
    # (`\e[?2026h` … `\e[?2026l`) atomically. Derived from emulator identity by
    # `Crysterm::Terminal::Capabilities.apply` (the true probe, DECRQM
    # `\e[?2026$p`, belongs in tput's startup batch alongside 2048/1016 — this
    # flag is where that reply would land).
    property? synchronized_output : Bool = false

    # Whether the terminal renders OSC 8 hyperlink escapes as clickable links.
    # Terminals without OSC 8 support may echo the URI payload into the
    # display, so emission is gated on this identity-derived flag.
    property? hyperlinks : Bool = false

    # Whether the terminal honors OSC 22 GUI pointer-shape requests
    # (xterm-class). Elsewhere OSC 22 is silently ignored, but there is no
    # point emitting it.
    property? pointer_shape : Bool = false
  end
end

module Crysterm
  # Tri-state policy for capabilities that can be auto-detected: follow the
  # detection (`Auto`), or force the feature regardless of it (`On`/`Off`).
  # The config-knob shape shared by `render.synchronized_output`,
  # `render.hyperlinks` and `mouse.cursor_shape` (mirroring `PixelMouse`).
  enum AutoToggle
    Auto # Enable when the terminal is identified as supporting the feature (and output is a real tty)
    On   # Always enable, trusting the terminal over the detection
    Off  # Never enable
  end

  module Terminal
    # Identity-derived terminal capabilities: fills the `Tput::Features` flags
    # that tput's startup probe does not populate itself, from the detected
    # emulator identity (env vars, `TERM`, and — after `Tput#probe!` — the
    # XTVERSION reply). Ran by `Screen` at construction and again after the
    # probe hardens the identity, mirroring the `Glyphs.detected_tier` cadence.
    #
    # The tables are deliberately conservative: a false negative only loses an
    # optimization/nicety (and `AutoToggle::On` overrides it), while a false
    # positive would emit escapes an incapable terminal might echo as garbage.
    module Capabilities
      # (Re)derives the identity-based feature flags on *tput*. Recomputes from
      # scratch, so a probe-refined identity can revoke an earlier guess; to
      # override, use the config knobs (`AutoToggle::On`/`Off`), not the flags.
      def self.apply(tput : ::Tput) : Nil
        return unless emulator = tput.emulator?
        f = tput.features
        f.synchronized_output = synchronized_output? emulator
        f.sources["synchronized_output"] = "derived from emulator identity"
        f.hyperlinks = hyperlinks? emulator
        f.sources["hyperlinks"] = "derived from emulator identity"
        f.pointer_shape = pointer_shape? emulator
        f.sources["pointer_shape"] = "derived from emulator identity"
      end

      # Whether the identified emulator presents DEC 2026 synchronized updates:
      # kitty, WezTerm, Ghostty, iTerm2, foot, Konsole, VTE ≥ 0.66
      # (gnome-terminal & co.), tmux ≥ 3.4. (*env* is injectable for specs.)
      def self.synchronized_output?(e : ::Tput::Emulator, env = ENV) : Bool
        e.kitty? || e.wezterm? || e.ghostty? || e.iterm2? || e.foot? ||
          e.konsole? || vte_at_least?(6600, env) || tmux_at_least?(e, 3, 4)
      end

      # Whether the identified emulator renders OSC 8 hyperlinks: kitty,
      # WezTerm, Ghostty, iTerm2, foot, Konsole, VTE ≥ 0.50, tmux ≥ 3.4.
      # Notably absent: xterm, rxvt, GNU screen, Apple Terminal.
      # (*env* is injectable for specs.)
      def self.hyperlinks?(e : ::Tput::Emulator, env = ENV) : Bool
        e.kitty? || e.wezterm? || e.ghostty? || e.iterm2? || e.foot? ||
          e.konsole? || vte_at_least?(5000, env) || tmux_at_least?(e, 3, 4)
      end

      # Whether the identified emulator honors OSC 22 pointer-shape requests:
      # genuine xterm, plus kitty and foot which adopted the xterm sequence.
      def self.pointer_shape?(e : ::Tput::Emulator) : Bool
        e.xterm? || e.kitty? || e.foot?
      end

      # Whether `$VTE_VERSION` reports at least *version* (VTE encodes 0.66.3
      # as `6603`). Unset/garbage counts as "no".
      private def self.vte_at_least?(version : Int32, env = ENV) : Bool
        (env["VTE_VERSION"]?.try(&.to_i?) || 0) >= version
      end

      # Whether the emulator is tmux of at least *major*.*minor*. tmux ≥ 3.2
      # self-identifies via `TERM_PROGRAM`/`TERM_PROGRAM_VERSION` (e.g. `3.4`,
      # `3.5a`); older tmux (no version info) counts as "no".
      private def self.tmux_at_least?(e : ::Tput::Emulator, major : Int32, minor : Int32) : Bool
        return false unless e.tmux? && e.term_program == "tmux"
        parts = e.term_program_version.split('.', 2)
        maj = parts[0]?.try(&.to_i?) || return false
        min = parts[1]?.try { |s| s.each_char.take_while(&.ascii_number?).join.to_i? } || 0
        {maj, min} >= {major, minor}
      end
    end
  end
end
