module Crysterm
  # Shared vocabulary for the chat widget family (`Widget::Chat::*` —
  # CHATBOX.md). Kept under `Crysterm::Chat` (not `Crysterm::Widget::Chat`) so
  # non-widget helpers (formatters, models) can use it without pulling in the
  # widget layer.
  module Chat
    # The fixed glyph set of the Claude-CLI-style chat interface (CHATBOX.md
    # Part 1 / §7.0), one constant per role, plus the CSS class-name vocabulary
    # every `Widget::Chat` widget styles against.
    #
    # Unlike the toolkit-wide tiered registry (`Crysterm::Glyphs`), these are
    # plain constants: the chat UI reproduces one specific interface whose
    # glyphs are part of the spec, so there is no per-tier retuning — an
    # application that needs an ASCII fallback can restyle at a higher level.
    module Glyphs
      # -- Entry prefixes ----------------------------------------------------
      # Settled output-line bullet (Claude uses `⏺` on macOS).
      BULLET = "⏺"
      # Settled output-line bullet, non-macOS variant.
      BULLET_ALT = "●"
      # Tool-result connector: indents a result block under its call.
      RESULT = "⎿"

      # -- Tree / nesting ----------------------------------------------------
      TREE_BRANCH = "├"
      TREE_LAST   = "└"
      TREE_PIPE   = "│"
      TREE_H      = "─"

      # -- Rounded input-border corners (Phase 2) ----------------------------
      ROUND_TL = "╭"
      ROUND_TR = "╮"
      ROUND_BL = "╰"
      ROUND_BR = "╯"
      # Input prompt chevron.
      PROMPT = "❯"
      # Breadcrumb / secondary chevron.
      PROMPT_ALT = "›"

      # -- State / status marks ---------------------------------------------
      OK             = "✓"
      OK_HEAVY       = "✔"
      FAIL           = "✗"
      PENDING        = "○"
      PENDING_ALT    = "◯"
      TODO_OPEN      = "☐"
      TODO_DONE      = "✓"
      TODO_CANCELLED = "☒"

      # -- Truncation / separators -------------------------------------------
      # Collapsed-block truncation marker (`… +N lines`).
      ELLIPSIS = "…"
      # Status-strip separator.
      MIDDOT = "·"
      ARROW  = "→"

      # Active-step "sparkle" spinner frames (§7.0): the star grows from a
      # middot to a full pinwheel, replacing the static `BULLET` while a step
      # runs. Frame timing is up to the animating widget (Claude: ~200 ms).
      SPINNER_FRAMES = {"·", "✢", "✳", "✶", "✻", "✽"}

      # -- CSS class names ---------------------------------------------------
      # The one shared styling vocabulary for chat widgets (Phase 0). Phase-2+
      # widgets tag themselves/entries with these via `add_css_class`, so an
      # application themes the whole chat UI with `.tool-call { … }` etc.
      CLASS_PROSE       = "prose"
      CLASS_TOOL_CALL   = "tool-call"
      CLASS_TOOL_RESULT = "tool-result"
      CLASS_DIFF        = "diff"
      CLASS_TODO        = "todo"
      CLASS_ERROR       = "error"
      CLASS_OK          = "ok"
      CLASS_FAIL        = "fail"
      CLASS_RUNNING     = "running"
      CLASS_PENDING     = "pending"
      CLASS_HINT        = "hint"
      CLASS_THINKING    = "thinking"
      CLASS_DIFF_ADD    = "diff-add"
      CLASS_DIFF_DEL    = "diff-del"
      CLASS_COLLAPSED   = "collapsed"
    end
  end
end
