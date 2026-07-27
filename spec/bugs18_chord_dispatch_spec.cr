require "./spec_helper"

# BUGS18 B18-95 + B18-98 — shared window-level shortcut dispatch.
#
# B18-95: dispatch used to be per-`Action` (each action its own window handler
# plus private chord state), so an earlier-installed action's single-stroke
# shortcut (Ctrl+S) fired on — and `accept`ed — the very keystroke that would
# have completed another action's chord (Ctrl+K, Ctrl+S): the chord could never
# fire, and which action won depended silently on installation order.
#
# B18-98: the per-action accelerator did `next if e.accepted?` before feeding
# its state machine, so a key consumed by any other handler skipped the
# prefix-clearing half entirely, leaving a half-entered chord prefix armed
# indefinitely (there is no inter-stroke timeout).
#
# Both are fixed by one per-window `Action::ShortcutMap` (Qt's `QShortcutMap`
# model): all installed sequences are matched together, a chord in progress
# owns its next stroke, and an already-consumed key still clears the pending
# prefix without ever firing.

private def press(win, key : Tput::Key)
  win.emit Crysterm::Event::KeyPress.new('\0', key)
end

# The classic VS Code-style pair: single-stroke Ctrl+S installed FIRST (the
# order that used to make the chord unreachable), chord Ctrl+K, Ctrl+S second.
private def save_and_chord(win)
  save = Crysterm::Action.new "Save", shortcut: Tput::Key::CtrlS
  kb = Crysterm::Action.new "Keybindings", shortcuts: [[Tput::Key::CtrlK, Tput::Key::CtrlS]]
  save.install_shortcut win
  kb.install_shortcut win
  {save, kb}
end

describe "BUGS18 B18-95/B18-98 shared window chord dispatch" do
  it "fires the chord, not the earlier-installed single-stroke action, when the prefix precedes (B18-95)" do
    win = headless_screen(80, 24)
    save, kb = save_and_chord win
    save_fired = 0
    kb_fired = 0
    save.on(Crysterm::Event::Triggered) { save_fired += 1 }
    kb.on(Crysterm::Event::Triggered) { kb_fired += 1 }

    press win, Tput::Key::CtrlK
    save_fired.should eq 0
    kb_fired.should eq 0 # prefix held, nothing fired yet
    press win, Tput::Key::CtrlS
    kb_fired.should eq 1   # the chord completes...
    save_fired.should eq 0 # ...and Save does NOT steal the completing stroke
  end

  it "still fires the single-stroke shortcut when no chord prefix is pending" do
    win = headless_screen(80, 24)
    save, kb = save_and_chord win
    save_fired = 0
    kb_fired = 0
    save.on(Crysterm::Event::Triggered) { save_fired += 1 }
    kb.on(Crysterm::Event::Triggered) { kb_fired += 1 }

    press win, Tput::Key::CtrlS # no pending prefix — plain save
    save_fired.should eq 1
    kb_fired.should eq 0

    # A completed chord clears the prefix, so a following lone Ctrl+S is
    # again the single-stroke action.
    press win, Tput::Key::CtrlK
    press win, Tput::Key::CtrlS
    kb_fired.should eq 1
    press win, Tput::Key::CtrlS
    save_fired.should eq 2
    kb_fired.should eq 1
  end

  it "clears a pending chord prefix when an intervening key is consumed by another handler (B18-98)" do
    win = headless_screen(80, 24)
    # Registered before the accelerators, so it consumes Ctrl+P first —
    # standing in for the focused widget's key walk / any other handler.
    win.on_key(:ctrl_p) { }
    save, kb = save_and_chord win
    save_fired = 0
    kb_fired = 0
    save.on(Crysterm::Event::Triggered) { save_fired += 1 }
    kb.on(Crysterm::Event::Triggered) { kb_fired += 1 }

    press win, Tput::Key::CtrlK # arm the chord prefix
    press win, Tput::Key::CtrlP # consumed upstream — must clear the prefix
    press win, Tput::Key::CtrlS # a fresh first stroke now
    kb_fired.should eq 0        # the stale prefix must NOT complete the chord
    save_fired.should eq 1      # cleared prefix: Ctrl+S is the plain shortcut

    # The full chord still works cleanly afterwards.
    press win, Tput::Key::CtrlK
    press win, Tput::Key::CtrlS
    kb_fired.should eq 1
    save_fired.should eq 1
  end

  it "re-tries a chord-breaking stroke as a fresh first stroke instead of swallowing it" do
    win = headless_screen(80, 24)
    save = Crysterm::Action.new "Save", shortcut: Tput::Key::CtrlS
    bold = Crysterm::Action.new "Bold", shortcuts: [[Tput::Key::CtrlK, Tput::Key::CtrlB]]
    save.install_shortcut win
    bold.install_shortcut win
    save_fired = 0
    bold_fired = 0
    save.on(Crysterm::Event::Triggered) { save_fired += 1 }
    bold.on(Crysterm::Event::Triggered) { bold_fired += 1 }

    press win, Tput::Key::CtrlK # arm [CtrlK] toward Ctrl+K, Ctrl+B
    press win, Tput::Key::CtrlS # breaks the chord — and is Save's shortcut
    bold_fired.should eq 0
    save_fired.should eq 1 # the breaking stroke fires as a fresh first stroke
  end
end
