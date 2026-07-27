require "./glyphs"
require "../scrollable_text"

module Crysterm
  class Widget
    # The chat widget family (CHATBOX.md): the pieces of a Claude-CLI-style
    # chat interface. Shared glyph/CSS vocabulary lives in
    # `Crysterm::Chat::Glyphs` (`src/widget/chat/glyphs.cr`).
    module Chat
      # The chat transcript (CHATBOX.md Phase 1): an append-only, scrollable
      # log of typed entries — prose, tool calls, tool results, diffs, todos,
      # errors — each rendered with a left prefix glyph (`⏺`/`⎿`/`✗`) and
      # optional state coloring, with long bodies collapsed behind a
      # `… +N lines` marker (toggled by `#toggle_collapse` / `Ctrl+O`).
      #
      # The model is deliberately small and agent-agnostic: an `Entry` is just
      # a kind, a text body, an optional running/ok/fail state, a nesting
      # depth and a collapsed flag. Nothing here knows about tools, models or
      # transports beyond those names.
      #
      # ### Rendering architecture / damage behavior
      #
      # Each entry renders — as a pure function of the entry plus
      # `#collapse_threshold` — to an array of `{}`-tag-styled logical lines,
      # cached per entry in `@rendered`. Tag-styled strings were chosen over
      # per-entry child widgets: entries are line-oriented text, so the
      # content pipeline (tag parse → wrap → attr scan → damage-tracked
      # paint) already does everything needed, while a widget per entry would
      # pay layout/positioning bookkeeping per entry for no gain.
      #
      # * `#append` pushes the new entry's lines through `Widget#append_line`,
      #   whose `append_content` fast path tag-parses/wraps **only the
      #   appended segment** and splices it onto the cached `_clines` tail —
      #   O(appended), never re-rendering prior entries' cached content. Every
      #   emitted line closes its own tags, so the fast path's
      #   "no open tag state at the boundary" precondition always holds.
      # * `#update_last` (the streaming case): when the previous rendering is
      #   a prefix of the new one (pure growth — new lines arrived), only the
      #   suffix is appended, staying on the O(appended) path. Otherwise the
      #   tail entry's lines are deleted and re-inserted, which goes through
      #   the line editors' full content rebuild — acceptable because it is
      #   bounded by stream-tick frequency, not by transcript length growth
      #   per se; if profiling ever shows it hot, retained-line caps /
      #   virtualized scrollback (CHATBOX.md Phase 10/§9.2) are the answer.
      # * `#toggle_collapse` re-renders just the toggled entry via the same
      #   delete+insert splice (full rebuild; user-interaction frequency).
      #
      # On-screen, the window's damage tracking then repaints only rows whose
      # cells actually changed, so an append repaints the new tail rows (plus
      # scroll shift, CSR-optimized), not the whole transcript.
      #
      # Auto-scroll uses the stock sticky-bottom machinery
      # (`Widget#follow_tail` + `#stick_to_tail?`): the view snaps to the new
      # bottom on growth **only when already at the bottom**; a reader who
      # scrolled up is never yanked down.
      class Transcript < ScrollableText
        # What an entry is — the transcript's only coupling to chat concepts.
        enum Kind
          Prose
          ToolCall
          ToolResult
          Diff
          Todo
          Error
        end

        # Lifecycle state of an entry (colors its prefix glyph). `nil` state
        # means "no state" (plain prose and the like).
        enum State
          Running
          Ok
          Fail
        end

        # One transcript entry. `text` always holds the **full** body;
        # collapsing is a render-time truncation, so expanding is lossless.
        class Entry
          property kind : Kind
          property text : String
          property state : State?
          # Extra nesting depth (2 columns each) — e.g. a tool result under a
          # nested sub-call.
          property depth : Int32
          # Whether an over-threshold body renders truncated. On by default so
          # long results arrive collapsed (matching the Claude CLI); has no
          # effect on bodies within the threshold.
          property collapsed : Bool

          def initialize(@kind : Kind, @text : String = "", *,
                         @state : State? = nil, @depth : Int32 = 0,
                         @collapsed : Bool = true)
          end

          # The untruncated body (alias of `#text`; retained in full even
          # while `#collapsed?` truncates the rendering).
          def full_text : String
            @text
          end
        end

        # Bodies over this many lines render truncated (`… +N lines`) while
        # their entry is collapsed.
        property collapse_threshold : Int32 = 10

        # The appended entries, oldest first. Read-only view; mutate through
        # `#append`/`#update_last`/`#toggle_collapse`.
        getter entries = [] of Entry

        # Rendered (tag-styled) logical lines per entry, parallel to
        # `#entries` — the per-entry cache that lets every content mutation
        # splice exactly the affected lines instead of rebuilding the whole
        # content string.
        @rendered = [] of Array(String)

        # Styled rendering needs the `{}`-tag pipeline.
        @parse_tags = true
        # Sticky-bottom (see the class doc).
        @follow_tail = true

        def initialize(collapse_threshold : Int32 = 10, **scrollable_text)
          super **scrollable_text

          @collapse_threshold = collapse_threshold

          on ::Crysterm::Event::ContentChanged, ->on_content_changed(::Crysterm::Event::ContentChanged)
          if @keys
            on ::Crysterm::Event::KeyPress, ->on_chat_keypress(::Crysterm::Event::KeyPress)
          end
        end

        # Appends *entry* to the transcript, renders it, and (when the view is
        # at the bottom) auto-scrolls to keep the tail visible.
        def append(entry : Entry) : Entry
          lines = render_entry entry
          @entries << entry
          @rendered << lines
          append_line lines.join('\n')
          entry
        end

        # Convenience: build and append an `Entry` in one call.
        def append(kind : Kind, text : String = "", *, state : State? = nil,
                   depth : Int32 = 0, collapsed : Bool = true) : Entry
          append Entry.new(kind, text, state: state, depth: depth, collapsed: collapsed)
        end

        # Replaces the live tail entry with *entry* (typically the same
        # object, mutated — the streaming case) and repaints it in place. The
        # entry list does not grow. Appends when the transcript is empty.
        def update_last(entry : Entry) : Entry
          if @entries.empty?
            return append entry
          end

          old = @rendered.last
          lines = render_entry entry
          @entries[-1] = entry
          @rendered[-1] = lines

          if lines.size >= old.size && lines[0, old.size] == old
            # Pure growth: the old rendering is a prefix of the new one, so
            # only the new lines need appending (O(appended) fast path).
            suffix = lines[old.size..]
            append_line suffix.join('\n') unless suffix.empty?
          else
            start = start_line_of @entries.size - 1
            delete_line start, old.size
            insert_line start, lines.join('\n')
          end
          entry
        end

        # Block form of `#update_last`: yields the tail entry for mutation,
        # then repaints it. Returns `nil` on an empty transcript.
        def update_last(& : Entry ->) : Entry?
          entry = @entries.last?
          return unless entry
          yield entry
          update_last entry
        end

        # Whether *entry*'s body exceeds `#collapse_threshold` (i.e. whether
        # collapsing changes its rendering at all).
        def collapsible?(entry : Entry) : Bool
          entry.text.count('\n') + 1 > @collapse_threshold
        end

        # Flips the collapsed state of the entry at *index* and re-renders
        # just that entry. Returns the new collapsed state, or `nil` for an
        # out-of-range index. Expansion is lossless (`Entry#text` always
        # retains the full body).
        def toggle_collapse(index : Int32) : Bool?
          entry = @entries[index]?
          return unless entry
          entry.collapsed = !entry.collapsed
          rerender_entry index
          entry.collapsed
        end

        # :ditto:
        def toggle_collapse(entry : Entry) : Bool?
          index = @entries.index(entry)
          return unless index
          toggle_collapse index
        end

        # The prefix glyph for an entry of *kind* (the state only picks the
        # color — see `.state_color`): `⏺` for prose/tool-call/todo, `⎿` for
        # a tool result, `✗` for an error; diffs carry no glyph (their body
        # lines are the decoration).
        def self.prefix_glyph(kind : Kind, state : State? = nil) : String
          case kind
          in .tool_result?
            ::Crysterm::Chat::Glyphs::RESULT
          in .error?
            ::Crysterm::Chat::Glyphs::FAIL
          in .diff?
            ""
          in .prose?, .tool_call?, .todo?
            ::Crysterm::Chat::Glyphs::BULLET
          end
        end

        # The `{}`-tag color name the prefix glyph is wrapped in, or `nil` for
        # unstyled: errors are always red; otherwise running → cyan,
        # ok → green, fail → red.
        def self.state_color(kind : Kind, state : State? = nil) : String?
          return "red" if kind.error?
          case state
          when State::Running then "cyan"
          when State::Ok      then "green"
          when State::Fail    then "red"
          end
        end

        # Escapes literal braces so untrusted text can't inject content tags
        # (`{` → `{open}`, `}` → `{close}` — single pass, so the braces of an
        # inserted `{open}` are never themselves re-escaped).
        def self.escape_braces(text : String) : String
          return text unless text.includes?('{') || text.includes?('}')
          text.gsub(/[{}]/) { |m| m == "{" ? "{open}" : "{close}" }
        end

        # `Ctrl+O` toggles the most recent collapsible entry (mirroring the
        # Claude CLI's expand/collapse key).
        def on_chat_keypress(e : ::Crysterm::Event::KeyPress)
          return unless e.key == ::Tput::Key::CtrlO
          index = @entries.rindex { |entry| collapsible? entry }
          return unless index
          toggle_collapse index
          e.accept
        end

        def on_content_changed(e)
          request_render
        end

        # Renders *entry* to its tag-styled logical lines (pure; no widget
        # state besides `#collapse_threshold` is read).
        private def render_entry(entry : Entry) : Array(String)
          body = entry.text.split('\n')
          hidden = 0
          if entry.collapsed && body.size > @collapse_threshold
            hidden = body.size - @collapse_threshold
            body = body[0, @collapse_threshold]
          end

          indent = "  " * entry.depth
          glyph = self.class.prefix_glyph(entry.kind, entry.state)
          color = self.class.state_color(entry.kind, entry.state)
          mark = color ? "{#{color}-fg}#{glyph}{/#{color}-fg}" : glyph

          # First-line prefix and the continuation indent that aligns
          # follow-on body lines under the first line's text column.
          first, cont =
            case entry.kind
            in .tool_result?
              {"#{indent}  #{mark}  ", "#{indent}     "}
            in .diff?
              {indent, indent}
            in .prose?, .tool_call?, .todo?, .error?
              {"#{indent}#{mark} ", "#{indent}  "}
            end

          out = Array(String).new(body.size + 1)
          body.each_with_index do |line, i|
            out << "#{i.zero? ? first : cont}#{style_body_line entry, line}"
          end
          if hidden > 0
            out << "#{cont}#{::Crysterm::Chat::Glyphs::ELLIPSIS} +#{hidden} lines"
          end
          out
        end

        # Per-line body styling: diff lines color by their leading `+`/`-`,
        # error bodies are red, everything else passes through (brace-escaped
        # so bodies can't inject tags).
        private def style_body_line(entry : Entry, line : String) : String
          esc = self.class.escape_braces line
          case entry.kind
          in .diff?
            if line.starts_with?('+')
              "{green-fg}#{esc}{/green-fg}"
            elsif line.starts_with?('-')
              "{red-fg}#{esc}{/red-fg}"
            else
              esc
            end
          in .error?
            "{red-fg}#{esc}{/red-fg}"
          in .prose?, .tool_call?, .todo?, .tool_result?
            esc
          end
        end

        # First logical (fake) content line of the entry at *index*.
        private def start_line_of(index : Int32) : Int32
          (0...index).sum { |i| @rendered.unsafe_fetch(i).size }
        end

        # Re-renders just the entry at *index*, splicing its new lines over
        # the old ones in place.
        private def rerender_entry(index : Int32) : Nil
          old = @rendered[index]
          lines = render_entry @entries[index]
          @rendered[index] = lines
          start = start_line_of index
          delete_line start, old.size
          insert_line start, lines.join('\n')
        end
      end
    end
  end
end
