module Crysterm
  # Shared vocabulary for the chat widget family (`Widget::Chat::*`). Kept
  # under `Crysterm::Chat` (not `Crysterm::Widget::Chat`) so non-widget
  # helpers (formatters, models) can use it without pulling in the widget
  # layer.
  module Chat
    # The fixed glyph set of the Claude-CLI-style chat interface, one constant
    # per role, plus the CSS class-name vocabulary every `Widget::Chat` widget
    # styles against.
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
      # Thinking/reasoning block marker (the sparkle's settled form).
      THINKING = "✻"

      # -- Tree / nesting ----------------------------------------------------
      TREE_BRANCH = "├"
      TREE_LAST   = "└"
      TREE_PIPE   = "│"
      TREE_H      = "─"

      # -- Rounded input-border corners --------------------------------------
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
      # `MIDDOT` as a ready-to-join segment separator (` · `).
      SEP   = " #{MIDDOT} "
      ARROW = "→"

      # Active-step "sparkle" spinner frames: the star grows from a middot to
      # a full pinwheel, replacing the static `BULLET` while a step runs.
      # Frame timing is up to the animating widget (Claude: ~200 ms).
      SPINNER_FRAMES = {"·", "✢", "✳", "✶", "✻", "✽"}

      # -- CSS class names ---------------------------------------------------
      # The one shared styling vocabulary for chat widgets. Widgets tag
      # themselves with these via `add_css_class`; transcript entries (logical
      # lines, not widgets) carry them through
      # `Widget::Chat::Transcript#entry_css_classes` and resolve colors via
      # its `#class_colors` table — so an application themes the whole chat UI
      # against one `.tool-call { … }`-style vocabulary.
      CLASS_PROSE       = "prose"
      CLASS_TOOL_CALL   = "tool-call"
      CLASS_TOOL_RESULT = "tool-result"
      CLASS_DIFF        = "diff"
      CLASS_TODO        = "todo"
      CLASS_ERROR       = "error"
      CLASS_OK          = "ok"
      CLASS_FAIL        = "fail"
      CLASS_RUNNING     = "running"
      CLASS_CANCELLED   = "cancelled"
      CLASS_PENDING     = "pending"
      CLASS_HINT        = "hint"
      CLASS_THINKING    = "thinking"
      CLASS_DIFF_ADD    = "diff-add"
      CLASS_DIFF_DEL    = "diff-del"
      CLASS_COLLAPSED   = "collapsed"

      # Default colors for the `CLASS_*` styling vocabulary, keyed by class
      # name — the one place the chat family's colors are defined.
      # `Widget::Chat::Transcript` and `Widget::Chat::TaskStrip` seed their
      # per-widget `#class_colors` copies from it (overridable via
      # `set_class_color`), and `Chat::Diff` resolves its add/del colors
      # through it, so all chat views color a given state alike.
      DEFAULT_CLASS_COLORS = {
        CLASS_RUNNING   => "cyan",
        CLASS_OK        => "green",
        CLASS_FAIL      => "red",
        CLASS_CANCELLED => "gray",
        CLASS_PENDING   => "gray",
        CLASS_ERROR     => "red",
        CLASS_HINT      => "yellow",
        CLASS_THINKING  => "gray",
        CLASS_DIFF_ADD  => "green",
        CLASS_DIFF_DEL  => "red",
        CLASS_COLLAPSED => "gray",
      }

      # The styling class of *state* (`CLASS_*` vocabulary).
      def self.state_class(state : State) : String
        case state
        in .running?   then CLASS_RUNNING
        in .ok?        then CLASS_OK
        in .fail?      then CLASS_FAIL
        in .cancelled? then CLASS_CANCELLED
        in .pending?   then CLASS_PENDING
        end
      end

      # The state mark of *state*: `○` pending, `✓` ok, `✗` fail/cancelled.
      # Running yields the first `SPINNER_FRAMES` frame — an animating view
      # substitutes the live frame itself.
      def self.glyph_for(state : State) : String
        case state
        in .pending?           then PENDING
        in .running?           then SPINNER_FRAMES[0]
        in .ok?                then OK
        in .fail?, .cancelled? then FAIL
        end
      end
    end

    # Lifecycle state of one unit of chat work, shared by every view of it:
    # transcript entries and background tasks carry the same five states, and
    # glyphs/classes/colors resolve through the one `Glyphs` vocabulary
    # (`Glyphs.state_class`, `Glyphs.glyph_for`,
    # `Glyphs::DEFAULT_CLASS_COLORS`). `Widget::Chat::Transcript::State` and
    # `Chat::Task::State` are aliases of this enum, so either spelling names
    # the same type.
    enum State
      Pending
      Running
      Ok
      Fail
      Cancelled

      # Whether the state is terminal: the work will not change again on its
      # own.
      def finished? : Bool
        ok? || fail? || cancelled?
      end
    end
  end
end
