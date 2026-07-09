# FEATURE: reactive state — signals, computeds, effects, bindings, observable
# collections, and signal-backed widget properties.
#
# One screen wired end-to-end with every piece of `Crysterm::Reactive` (see
# REACTIVE.md). Application state lives in signals; widgets are driven from it
# declaratively. A timer mutates the state; nothing calls `render` by hand — each
# reactive change schedules a repaint on the shared render doorbell.
#
# Keys:  p +5   m toggle mode   t toggle theme   b batch update
#        a append log   c clear log   q / Ctrl-Q quit
#
# Feature map (labelled inline below):
#   (1) Signal(T)               — observable value cells
#   (2) Computed(T)             — derived values that recompute automatically
#   (3) Reactive.bind           — permanent binding: widget prop <- signal(s)
#   (4) Reactive.effect         — auto-tracking effect with dynamic dependencies
#   (5) Reactive.batch          — coalesce many writes into one update
#   (6) Reactive.untracked      — read a signal without depending on it
#   (7) ObservableList + bind_items — granular, patch-not-rebuild list binding
#   (8) reactive_property macro — signal-backed widget property

require "../../src/crysterm"

include Crysterm

# (8) A custom widget with a signal-backed property. Assigning `#status` notifies
# bindings/effects, marks the widget dirty, and schedules a repaint; `#status`
# read inside an effect auto-tracks; `#status_signal` is the bindable Signal.
class StatusLabel < Widget::Box
  # ameba:disable Lint/UselessAssign
  reactive_property status : String = "idle"
end

s = Window.new title: "Crysterm — Reactive"

# ---- application state -------------------------------------------------------

# (1) Signals: the single source of truth the whole UI derives from.
count = Reactive::Signal.new 0
mode = Reactive::Signal.new true    # switches which signal the info effect reads
theme = Reactive::Signal.new "dark" # read untracked by the footer

# (2) Computeds: derived, memoized, recomputed only when their inputs change.
doubled = Reactive::Computed(Int32).new { count.value * 2 }
percent = Reactive::Computed(Int32).new { count.value % 101 }

# (7) An observable collection driving a List; mutations patch just the rows.
log = Reactive::ObservableList(String).new ["log started"]

# ---- widgets -----------------------------------------------------------------

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Crysterm reactive demo — p:+5  m:mode  t:theme  b:batch  a:add  c:clear  q:quit{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#303050")

count_box = Widget::Box.new \
  parent: s, top: 2, left: 0, width: 30, height: 3,
  parse_tags: true,
  style: Style.new(fg: "cyan", bg: "black", border: true)

doubled_box = Widget::Box.new \
  parent: s, top: 5, left: 0, width: 30, height: 3,
  parse_tags: true,
  style: Style.new(fg: "green", bg: "black", border: true)

progress = Widget::ProgressBar.new \
  parent: s, top: 8, left: 0, width: 30, height: 3,
  content: "{center}percent{/center}", parse_tags: true, filled: 0,
  style: Style.new(fg: "yellow", bg: "#303030", border: true)

status = StatusLabel.new \
  parent: s, top: 11, left: 0, width: 30, height: 3,
  parse_tags: true,
  style: Style.new(fg: "magenta", bg: "black", border: true)

info = Widget::Box.new \
  parent: s, top: 14, left: 0, width: 30, height: 3,
  parse_tags: true,
  style: Style.new(fg: "white", bg: "#202020", border: true)

footer = Widget::Box.new \
  parent: s, top: 17, left: 0, width: 30, height: 1,
  style: Style.new(fg: "gray", bg: "black")

log_list = Widget::List.new \
  parent: s, top: 2, left: 31, width: 47, height: 16,
  style: Style.new(fg: "white", bg: "black", border: true)

# ---- reactive wiring ---------------------------------------------------------

# (3) bind: permanent binding. `count_box` re-renders whenever `count` changes.
# Dependencies are explicit (named signals); the block does the assignment.
Reactive.bind(count_box, count) do
  count_box.content = "{center}Count: #{count.value}{/center}"
end

# (3) bind to a Computed — `doubled` emits only when its result actually changes.
Reactive.bind(doubled_box, doubled) do
  doubled_box.content = "{center}Doubled: #{doubled.value}{/center}"
end

# (3) bind a Computed onto a numeric widget property.
Reactive.bind(progress, percent) do
  progress.filled = percent.value
end

# (8) + (4): drive the reactive_property from an effect (auto-tracks `count`),
# and mirror the property onto the label's content with a bind on its signal.
Reactive.effect(status) do
  status.status = count.value.even? ? "EVEN #{count.value}" : "ODD #{count.value}"
end
Reactive.bind(status, status.status_signal) do
  status.content = "{center}Parity: #{status.status}{/center}"
end

# (4) effect with a DYNAMIC dependency set: when `mode` is true it reads `count`;
# when false it reads `doubled`. Re-tracking drops the unused dependency each run,
# so toggling `mode` changes what this effect depends on. Auto-discovered — no
# signals are named.
Reactive.effect(info) do
  txt = mode.value ? "Mode A · count=#{count.value}" : "Mode B · doubled=#{doubled.value}"
  info.content = "{center}#{txt}{/center}"
end

# The theme, applied for real. This effect TRACKS `theme`, so pressing `t` (or
# the timer's periodic flip) recolors every panel the instant `theme` changes.
# Colors are the Breeze light/dark palettes (data/css/breeze-*.qss): those QSS
# sheets only match Qt widget types, not this demo's bare Boxes, so we apply
# their palette directly to each widget's style.
BREEZE_DARK_BG  = "#31363b"
BREEZE_DARK_FG  = "#eff0f1"
BREEZE_LIGHT_BG = "#eff0f1"
BREEZE_LIGHT_FG = "#31363b"
themed = [count_box, doubled_box, progress, status, info, footer, log_list]
Reactive.effect do
  bg, fg = theme.value == "dark" ? {BREEZE_DARK_BG, BREEZE_DARK_FG} : {BREEZE_LIGHT_BG, BREEZE_LIGHT_FG}
  themed.each do |w|
    w.css_inline_style.try do |st|
      st.bg = bg
      st.fg = fg
    end
    w.mark_dirty
  end
  s.render
end

# (6) untracked: this effect depends on `count` but reads `theme` WITHOUT
# depending on it — the theme write above recolors the UI immediately, yet this
# footer label only catches up on the next `count` tick (the untracked read
# means the theme change does not re-run it). That lag is the demonstration.
Reactive.effect(footer) do
  t = Reactive.untracked { theme.value }
  footer.content = " count=#{count.value}  theme=#{t}"
end

# (7) bind_items: keep the List in sync with the ObservableList. Each granular
# change (push/shift/clear/insert/[]=) patches only the affected rows.
Reactive.bind_items(log_list, log, &.itself)

# ---- drivers -----------------------------------------------------------------

# Timer-driven by default: with no keypresses at all, the clock exercises every
# reactive feature on a cycle, so an animated screenshot shows the whole system
# working. Keys below still allow manual interaction.
i = 0
s.every(0.2.seconds) do
  count.value += 1                     # (1) plain signal write
  count.value = 0 if count.value > 999 #     -> (2) computeds, (3) binds

  log << "tick #{i} (count=#{count.value})" if i % 3 == 0 # (7) append -> one new row
  log.shift if log.size > 12                              # (7) remove -> one row gone

  mode.update { |v| !v } if i % 10 == 0 # (4) flips the info effect's deps

  # (6) flip the theme; the footer is untracked on it, so it only reflects the
  # new value on the following tick (when `count` changes) — visible in the anim.
  theme.update { |v| v == "dark" ? "light" : "dark" } if i % 15 == 0

  # (5) periodic batch: two writes settle, dependents run once.
  if i > 0 && i % 25 == 0
    Reactive.batch do
      count.value += 50
      mode.update { |v| !v }
    end
  end

  i += 1
end

s.on(Crysterm::Event::KeyPress) do |e|
  case e.char
  when 'p'
    count.value += 5 # (1) plain signal write
  when 'm'
    mode.update { |v| !v } # (1) update: transform in place -> (4) re-tracks
  when 't'
    theme.update { |v| v == "dark" ? "light" : "dark" } # (6) footer won't move until next tick
  when 'b'
    # (5) batch: both writes settle, then dependent effects/bindings run ONCE.
    Reactive.batch do
      count.value += 100
      mode.update { |v| !v }
    end
  when 'a'
    log << "manual entry ##{log.size}" # (7) explicit append
  when 'c'
    log.clear # (7) Reset -> list rebuilds empty
  end
end

s.exec
