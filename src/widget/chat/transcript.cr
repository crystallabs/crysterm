require "../../chat/glyphs"
require "../../formatting"
require "../scrollable_text"

module Crysterm
  class Widget
    # The chat widget family: the pieces of a Claude-CLI-style chat
    # interface. Shared glyph/CSS vocabulary lives in
    # `Crysterm::Chat::Glyphs` (`src/chat/glyphs.cr`).
    module Chat
      # The chat transcript: an append-only, scrollable log of typed entries
      # — prose, tool calls, tool results, diffs, todos, notices, thinking
      # blocks, errors — each rendered with a left prefix glyph
      # (`⏺`/`⎿`/`✗`/`✻`) and optional state coloring, with long bodies
      # collapsed behind a `… +N lines (Ctrl+O)` marker (toggled by
      # `#toggle_collapse`, `Ctrl+O`, or a click on the entry's header).
      #
      # The model is deliberately small and agent-agnostic: an `Entry` is just
      # a kind, a text body, an optional running/ok/fail/cancelled/pending
      # state, a nesting depth, an optional parent link and a collapsed flag.
      # Nothing here knows about tools, models or transports beyond those
      # names.
      #
      # ### Tree structure
      #
      # An entry may name a `parent` (a tool result belongs to its call; a
      # sub-call belongs to the call that spawned it). Children render
      # connected to their parent with the tree glyph set — `⎿` for a tool
      # result, `├`/`└` for other children, with `│` spine columns carrying
      # the link past intervening lines — and collapsing a parent folds its
      # whole subtree behind the parent's marker. Every toggle emits
      # `Event::Expanded`/`Event::Collapsed` with the entry's index.
      #
      # ### Rendering architecture / damage behavior
      #
      # Each entry renders to an array of `{}`-tag-styled logical lines,
      # cached per entry in `@rendered` — a function of the entry, its
      # ancestors/siblings (tree connectors, subtree folding) and
      # `#collapse_threshold`. Tag-styled strings were chosen over per-entry
      # child widgets: entries are line-oriented text, so the content
      # pipeline (tag parse → wrap → attr scan → damage-tracked paint)
      # already does everything needed, while a widget per entry would pay
      # layout/positioning bookkeeping per entry for no gain.
      #
      # The bookkeeping around the cache is incremental too: each entry
      # caches its parsed body lines (markdown import / line split) on
      # itself, invalidated by `Entry#text=`, so re-renders, fold-marker
      # line counts and theme changes never re-import an unchanged body;
      # entry start offsets are running prefix sums of `@rendered` sizes
      # patched with the known delta at each splice; and entry→index lookup
      # is an identity hash. No mutation path rescans the transcript.
      #
      # * `#append` pushes the new entry's lines through `Widget#append_line`,
      #   whose `append_content` fast path tag-parses/wraps **only the
      #   appended segment** and splices it onto the cached `_clines` tail —
      #   O(appended), never re-rendering prior entries' cached content.
      #   Appending a later sibling re-splices just the previous sibling's
      #   subtree (its `└` becomes `├` and its spine gains a column).
      # * `#update_last` (the streaming case): when the previous rendering is
      #   a prefix of the new one (pure growth — new lines arrived), only the
      #   suffix is appended, staying on the O(appended) path. Otherwise the
      #   tail entry's lines are deleted and re-inserted, which goes through
      #   the line editors' full content rebuild — acceptable because it is
      #   bounded by stream-tick frequency, not by transcript length.
      # * `#toggle_collapse` re-renders the toggled entry and its subtree via
      #   the same delete+insert splice (user-interaction frequency).
      #
      # On-screen, the window's damage tracking then repaints only rows whose
      # cells actually changed, so an append repaints the new tail rows (plus
      # scroll shift, CSR-optimized), not the whole transcript.
      #
      # Auto-scroll uses the stock sticky-bottom machinery
      # (`Widget#follow_tail` + `#stick_to_tail?`): the view snaps to the new
      # bottom on growth **only when already at the bottom**; a reader who
      # scrolled up is never yanked down.
      #
      # ### Styling
      #
      # Entries carry the `Crysterm::Chat::Glyphs::CLASS_*` vocabulary
      # (`#entry_css_classes`); rendering resolves each class through
      # `#class_colors` (seeded from `DEFAULT_CLASS_COLORS`, per-class
      # overridable via `#set_class_color`). Entries are logical lines rather
      # than widgets, so this table — not the widget CSS cascade, which
      # styles only widget nodes — is what a `.tool-call { … }`-style theme
      # keys into.
      class Transcript < ScrollableText
        # What an entry is — the transcript's only coupling to chat concepts.
        enum Kind
          Prose
          ToolCall
          ToolResult
          Diff
          Todo
          Notice
          Thinking
          Error
        end

        # Lifecycle state of an entry (colors — and for pending/todo, picks —
        # its prefix glyph). `nil` state means "no state" (plain prose and
        # the like). The shared `Crysterm::Chat::State`, so entries and
        # `Chat::Task`s speak one state vocabulary.
        alias State = ::Crysterm::Chat::State

        # One transcript entry. `text` always holds the **full** body;
        # collapsing is a render-time truncation, so expanding is lossless.
        class Entry
          property kind : Kind
          getter text : String
          property state : State?
          # Extra nesting depth (2 columns each) on top of any parent-link
          # nesting.
          property depth : Int32
          # Whether an over-threshold body renders truncated — and, for an
          # entry with children, whether the subtree is folded. On by default
          # so long results arrive collapsed (matching the Claude CLI); has
          # no effect on bodies within the threshold. `Transcript#append`
          # clears it on a short-bodied parent when its first child arrives,
          # so subtrees start open and folding stays an explicit gesture.
          property collapsed : Bool
          # The entry this one belongs to (a tool result's call; a sub-call's
          # spawning call). Fixed at construction, which also wires the
          # parent's `#children`.
          getter parent : Entry?
          # Child entries, oldest first (see `#parent`).
          getter children = [] of Entry

          # Renderable body lines (`Transcript#body_lines` output), keyed by
          # whether the markdown importer produced them; `nil` until first
          # computed and after every body change. Caching here — rather than
          # in the widget — ties the cache's life to the text it was built
          # from.
          @body_cache : Array(String)?
          @body_cache_markdown = false

          def initialize(@kind : Kind, @text : String = "", *,
                         @state : State? = nil, @depth : Int32 = 0,
                         @collapsed : Bool = true, parent : Entry? = nil)
            @parent = parent
            parent.children << self if parent
          end

          # Replaces the body. Invalidates the cached rendered lines, so the
          # next render re-imports/re-splits the new text.
          def text=(text : String)
            @body_cache = nil unless text == @text
            @text = text
          end

          # :nodoc:
          # The cached body lines, provided they were built with the same
          # *markdown* setting — a mismatch (kind or `#prose_markdown?`
          # changed) reads as a miss.
          def cached_body(markdown : Bool) : Array(String)?
            cache = @body_cache
            cache if cache && @body_cache_markdown == markdown
          end

          # :nodoc:
          # Stores freshly computed body lines (see `#cached_body`). The
          # array is shared, never mutated by rendering.
          def cache_body(lines : Array(String), markdown : Bool) : Array(String)
            @body_cache = lines
            @body_cache_markdown = markdown
            lines
          end

          # The untruncated body (alias of `#text`; retained in full even
          # while `#collapsed?` truncates the rendering).
          def full_text : String
            @text
          end

          # Whether this entry is (currently) the last child of its parent.
          # Vacuously true for a parentless entry.
          def last_child? : Bool
            p = @parent
            !p || p.children.last.same?(self)
          end
        end

        # Default colors for the `Crysterm::Chat::Glyphs::CLASS_*` styling
        # vocabulary — the shared `Glyphs::DEFAULT_CLASS_COLORS` table, one
        # vocabulary for every chat view. Instance rendering reads the
        # per-widget `#class_colors` copy; this constant also backs the
        # class-level `.state_color`.
        DEFAULT_CLASS_COLORS = ::Crysterm::Chat::Glyphs::DEFAULT_CLASS_COLORS

        # Bodies over this many lines render truncated (`… +N lines`) while
        # their entry is collapsed.
        property collapse_threshold : Int32 = 10

        # Whether prose bodies pass through the markdown importer
        # (`TextDocumentFragment.from_markdown` → tag text) before rendering.
        # Off, prose renders as plain (brace-escaped) text.
        property? prose_markdown = true

        # The per-widget class-name → color table rendering resolves the
        # entry CSS classes against. Mutate via `#set_class_color` so
        # existing entries re-render.
        getter class_colors : Hash(String, String) = DEFAULT_CLASS_COLORS.dup

        # The appended entries, oldest first. Read-only view; mutate through
        # `#append`/`#update_last`/`#toggle_collapse`.
        getter entries = [] of Entry

        # Rendered (tag-styled) logical lines per entry, parallel to
        # `#entries` — the per-entry cache that lets every content mutation
        # splice exactly the affected lines instead of rebuilding the whole
        # content string. An entry folded under a collapsed ancestor caches
        # an empty array.
        @rendered = [] of Array(String)

        # First fake (logical) line of each rendered entry, parallel to
        # `@rendered` — running prefix sums, patched with the known delta at
        # every splice, so offset lookups are O(1) instead of a rescan.
        @starts = [] of Int32

        # Entry identity (`object_id`) → index in `#entries`, replacing
        # linear identity scans. Entries are only ever appended (the tail may
        # be swapped by `#update_last`), so maintenance is O(1) per mutation.
        @entry_index = {} of UInt64 => Int32

        # Styled rendering needs the `{}`-tag pipeline.
        @parse_tags = true
        # Sticky-bottom (see the class doc).
        @follow_tail = true

        def initialize(collapse_threshold : Int32 = 10, **scrollable_text)
          super **scrollable_text

          @collapse_threshold = collapse_threshold

          on ::Crysterm::Event::ContentChanged, ->handle_content_changed(::Crysterm::Event::ContentChanged)
          if @keys
            on ::Crysterm::Event::KeyPress, ->handle_chat_key_press(::Crysterm::Event::KeyPress)
          end
          on ::Crysterm::Event::Mouse, ->handle_chat_mouse(::Crysterm::Event::Mouse)
        end

        # Appends *entry* to the transcript, renders it, and (when the view is
        # at the bottom) auto-scrolls to keep the tail visible. A parent-linked
        # entry also re-splices the previous sibling's subtree (its connector
        # changes from `└` to `├`) and, when it lands inside a folded subtree,
        # the folding ancestor's marker line.
        def append(entry : Entry) : Entry
          @entries << entry
          @entry_index[entry.object_id] = @entries.size - 1

          if (parent = entry.parent) && parent.children.size == 1 &&
             parent.collapsed && !body_over_threshold?(parent)
            # A first child arriving under a short-bodied parent opens the
            # subtree: folding is an explicit gesture, not the arrival
            # default (which only means "truncate a long body").
            parent.collapsed = false
          end

          if (parent = entry.parent) && (prev = parent.children[-2]?)
            rerender_tree prev
          end

          lines = render_entry entry
          @starts << total_rendered_lines
          @rendered << lines
          append_line lines.join('\n') unless lines.empty?

          refresh_fold_marker entry
          entry
        end

        # Convenience: build and append an `Entry` in one call.
        def append(kind : Kind, text : String = "", *, state : State? = nil,
                   depth : Int32 = 0, collapsed : Bool = true,
                   parent : Entry? = nil) : Entry
          append Entry.new(kind, text, state: state, depth: depth,
            collapsed: collapsed, parent: parent)
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
          prev = @entries[-1]
          unless prev.same? entry
            @entry_index.delete prev.object_id
            @entry_index[entry.object_id] = @entries.size - 1
          end
          @entries[-1] = entry
          @rendered[-1] = lines

          if prefix_of?(old, lines)
            # Pure growth: the old rendering is a prefix of the new one, so
            # only the new lines need appending (O(appended) fast path).
            suffix = lines[old.size..]
            append_line suffix.join('\n') unless suffix.empty?
          else
            start = start_line_of @entries.size - 1
            delete_line start, old.size unless old.empty?
            insert_line start, lines.join('\n') unless lines.empty?
          end

          refresh_fold_marker entry
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

        # Whether *entry* toggles: an over-threshold body (collapsing
        # truncates it) or any children (collapsing folds the subtree). The
        # body test counts raw text lines, so for markdown prose it is an
        # approximation of the rendered count.
        def collapsible?(entry : Entry) : Bool
          !entry.children.empty? || body_over_threshold?(entry)
        end

        # Flips the collapsed state of the entry at *index*, re-renders it
        # and its subtree, and emits `Event::Expanded`/`Event::Collapsed`
        # (with *index*). Returns the new collapsed state, or `nil` for an
        # out-of-range index. Expansion is lossless (`Entry#text` always
        # retains the full body).
        def toggle_collapse(index : Int32) : Bool?
          entry = @entries[index]?
          return unless entry
          entry.collapsed = !entry.collapsed
          rerender_tree entry
          if entry.collapsed
            emit ::Crysterm::Event::Collapsed, index
          else
            emit ::Crysterm::Event::Expanded, index
          end
          entry.collapsed
        end

        # :ditto:
        def toggle_collapse(entry : Entry) : Bool?
          index = index_of entry
          return unless index
          toggle_collapse index
        end

        # The prefix glyph for an entry of *kind*: `⏺` for
        # prose/tool-call/todo/notice (`○` when pending; the todo states pick
        # their checkbox mark), `⎿` for a tool result, `✗` for an error, `✻`
        # for a thinking block; diffs carry no glyph (their body lines are
        # the decoration). The state otherwise only picks the color — see
        # `.state_color`.
        def self.prefix_glyph(kind : Kind, state : State? = nil) : String
          case kind
          in .tool_result?
            ::Crysterm::Chat::Glyphs::RESULT
          in .error?
            ::Crysterm::Chat::Glyphs::FAIL
          in .diff?
            ""
          in .thinking?
            ::Crysterm::Chat::Glyphs::THINKING
          in .todo?
            case state
            when State::Pending   then ::Crysterm::Chat::Glyphs::TODO_OPEN
            when State::Ok        then ::Crysterm::Chat::Glyphs::TODO_DONE
            when State::Cancelled then ::Crysterm::Chat::Glyphs::TODO_CANCELLED
            else                       ::Crysterm::Chat::Glyphs::BULLET
            end
          in .prose?, .tool_call?, .notice?
            state == State::Pending ? ::Crysterm::Chat::Glyphs::PENDING : ::Crysterm::Chat::Glyphs::BULLET
          end
        end

        # The styling class of *kind* (`Crysterm::Chat::Glyphs::CLASS_*`).
        def self.kind_class(kind : Kind) : String
          case kind
          in .prose?       then ::Crysterm::Chat::Glyphs::CLASS_PROSE
          in .tool_call?   then ::Crysterm::Chat::Glyphs::CLASS_TOOL_CALL
          in .tool_result? then ::Crysterm::Chat::Glyphs::CLASS_TOOL_RESULT
          in .diff?        then ::Crysterm::Chat::Glyphs::CLASS_DIFF
          in .todo?        then ::Crysterm::Chat::Glyphs::CLASS_TODO
          in .notice?      then ::Crysterm::Chat::Glyphs::CLASS_HINT
          in .thinking?    then ::Crysterm::Chat::Glyphs::CLASS_THINKING
          in .error?       then ::Crysterm::Chat::Glyphs::CLASS_ERROR
          end
        end

        # The styling class of *state* (`Crysterm::Chat::Glyphs::CLASS_*`).
        def self.state_class(state : State) : String
          ::Crysterm::Chat::Glyphs.state_class state
        end

        # The styling classes *entry* carries: its kind class, its state
        # class (when stateful), and `collapsed` while it renders folded.
        def entry_css_classes(entry : Entry) : Array(String)
          out = [self.class.kind_class(entry.kind)]
          entry.state.try { |s| out << self.class.state_class(s) }
          out << ::Crysterm::Chat::Glyphs::CLASS_COLLAPSED if entry.collapsed && collapsible?(entry)
          out
        end

        # Overrides (or with `nil`, clears) the color of a styling class and
        # re-renders every entry, so a theme change applies to existing
        # content.
        def set_class_color(name : String, color : String?) : Nil
          if color
            @class_colors[name] = color
          else
            @class_colors.delete name
          end
          @entries.each_index { |i| rerender_entry i }
        end

        # The default `{}`-tag color name the prefix glyph is wrapped in, or
        # `nil` for unstyled — the `DEFAULT_CLASS_COLORS` entry of the state
        # class (kind class for the always-colored error/notice/thinking
        # kinds). Instance rendering resolves through `#class_colors` instead.
        def self.state_color(kind : Kind, state : State? = nil) : String?
          return DEFAULT_CLASS_COLORS[::Crysterm::Chat::Glyphs::CLASS_ERROR] if kind.error?
          if state
            DEFAULT_CLASS_COLORS[state_class(state)]?
          elsif kind.notice? || kind.thinking?
            DEFAULT_CLASS_COLORS[kind_class(kind)]?
          end
        end

        # Toggles the most recent visible collapsible entry — the `Ctrl+O`
        # expand/collapse action, public so a composer-level accelerator can
        # drive it while focus is elsewhere (e.g. in the chat input). Returns
        # the entry's new collapsed state, or `nil` when nothing was
        # collapsible.
        def toggle_recent : Bool?
          index = @entries.rindex { |entry| collapsible?(entry) && !hidden_by_ancestor?(entry) }
          return unless index
          toggle_collapse index
        end

        # `Ctrl+O` toggles the most recent visible collapsible entry
        # (mirroring the Claude CLI's expand/collapse key).
        def handle_chat_key_press(e : ::Crysterm::Event::KeyPress)
          return unless e.key == ::Tput::Key::CtrlO
          e.accept unless toggle_recent.nil?
        end

        # A left click on a collapsible entry's header line (or on its
        # `… +N lines` marker) toggles it.
        def handle_chat_mouse(e : ::Crysterm::Event::Mouse)
          return unless e.action.down? && e.button.left?
          row = @child_base + e.local_y
          rtof = @_clines.rtof
          return if row < 0 || row >= rtof.size
          fake = rtof[row]
          index = entry_index_at fake
          return unless index
          entry = @entries[index]
          return unless collapsible?(entry) && !hidden_by_ancestor?(entry)
          rel = fake - start_line_of(index)
          return unless rel.zero? || (entry.collapsed && rel == @rendered[index].size - 1)
          toggle_collapse index
          e.accept
        end

        def handle_content_changed(e)
          update!
        end

        # Whether *entry*'s raw body exceeds `#collapse_threshold`.
        private def body_over_threshold?(entry : Entry) : Bool
          entry.text.count('\n') + 1 > @collapse_threshold
        end

        # Whether *entry* is folded away under some collapsed ancestor.
        private def hidden_by_ancestor?(entry : Entry) : Bool
          node = entry.parent
          while node
            return true if node.collapsed
            node = node.parent
          end
          false
        end

        # The entry whose marker line folds *entry* away: the outermost
        # collapsed ancestor — anything collapsed below it is itself folded,
        # so the outermost is the one whose marker shows. `nil` when no
        # ancestor is collapsed. A single upward walk (the nested
        # per-ancestor visibility test would be O(depth²)).
        private def fold_ancestor(entry : Entry) : Entry?
          fold = nil
          node = entry.parent
          while node
            fold = node if node.collapsed
            node = node.parent
          end
          fold
        end

        # Re-splices the marker line of the ancestor folding *entry*, if any
        # (its hidden-line count changed).
        private def refresh_fold_marker(entry : Entry) : Nil
          fold = fold_ancestor(entry)
          return unless fold
          index = index_of fold
          rerender_entry index if index
        end

        # Index of *entry* (by identity), or `nil` when not (yet) appended —
        # O(1) via `@entry_index`.
        private def index_of(entry : Entry) : Int32?
          @entry_index[entry.object_id]?
        end

        # Re-renders *root* and every already-appended descendant, in place —
        # a subtree walk over the `children` links (splice order doesn't
        # matter: each entry's rendering depends only on the entry model, and
        # `@starts` is patched per splice). A constructed-but-unappended
        # descendant has no index and is skipped.
        private def rerender_tree(root : Entry) : Nil
          if (i = index_of(root)) && i < @rendered.size
            rerender_entry i
          end
          root.children.each { |child| rerender_tree child }
        end

        # The entry index owning fake (logical) line *fake*, or `nil` past
        # the end. Binary search over the `@starts` prefix sums; among
        # entries sharing a start (zero-line renderings), the owner is the
        # last — the only one with lines.
        private def entry_index_at(fake : Int32) : Int32?
          return if fake < 0 || fake >= total_rendered_lines
          i = @starts.bsearch_index { |s| s > fake } || @starts.size
          i - 1
        end

        # The body of *entry* as renderable lines: markdown-imported tag text
        # for prose (see `#prose_markdown?`), the raw text split into lines
        # otherwise. Cached on the entry (invalidated by `Entry#text=`, keyed
        # by the markdown decision), so re-renders, marker line counts and
        # theme changes never re-import an unchanged body. Callers must not
        # mutate the returned array.
        private def body_lines(entry : Entry) : Array(String)
          markdown = prose_body?(entry)
          entry.cached_body(markdown) || begin
            lines =
              if markdown
                ::Crysterm::TextDocumentFragment.from_markdown(entry.text).to_tags.split('\n')
              else
                entry.text.split('\n')
              end
            entry.cache_body(lines, markdown)
          end
        end

        # Whether *entry*'s body goes through the markdown importer (and so
        # arrives pre-styled — no brace escaping).
        private def prose_body?(entry : Entry) : Bool
          entry.kind.prose? && prose_markdown? && !entry.text.empty?
        end

        # How many lines *entry* and its currently-unfolded descendants would
        # occupy were its own ancestors expanded — what a folding ancestor's
        # marker counts.
        private def visible_line_count(entry : Entry) : Int32
          body = body_lines(entry).size
          hidden = entry.collapsed && body > @collapse_threshold ? body - @collapse_threshold : 0
          n = body - hidden
          n += 1 if entry.collapsed && (hidden > 0 || !entry.children.empty?)
          unless entry.collapsed
            entry.children.each { |c| n += visible_line_count(c) }
          end
          n
        end

        # The color rendering wraps *entry*'s prefix glyph/connector in
        # (resolved through `#class_colors`); `nil` for unstyled.
        private def glyph_color(entry : Entry) : String?
          return class_color(::Crysterm::Chat::Glyphs::CLASS_ERROR) if entry.kind.error?
          if state = entry.state
            class_color(self.class.state_class(state))
          elsif entry.kind.notice? || entry.kind.thinking?
            class_color(self.class.kind_class(entry.kind))
          end
        end

        private def class_color(name : String) : String?
          @class_colors[name]?
        end

        private def colorize(text : String, color : String?) : String
          color ? "{#{color}-fg}#{text}{/#{color}-fg}" : text
        end

        # First-line lead and continuation lead of a parent-linked entry: one
        # two-column slot per ancestor — `│` while that ancestor still has
        # later siblings — then the entry's own connector (`⎿` for a tool
        # result, `├`/`└` otherwise, state-colored like a prefix glyph).
        private def tree_lead(entry : Entry) : {String, String}
          cols = String.build do |s|
            chain = [] of Entry
            node = entry.parent
            while node
              chain.unshift node
              node = node.parent
            end
            chain.each do |a|
              s << "  " * a.depth
              if a.parent
                s << (a.last_child? ? "  " : "#{::Crysterm::Chat::Glyphs::TREE_PIPE} ")
              else
                s << "  "
              end
            end
            s << "  " * entry.depth
          end

          color = glyph_color(entry)
          spine = entry.last_child? ? " " : ::Crysterm::Chat::Glyphs::TREE_PIPE
          if entry.kind.tool_result?
            {"#{cols}#{colorize(::Crysterm::Chat::Glyphs::RESULT, color)}  ", "#{cols}#{spine}  "}
          else
            conn = entry.last_child? ? ::Crysterm::Chat::Glyphs::TREE_LAST : ::Crysterm::Chat::Glyphs::TREE_BRANCH
            {"#{cols}#{colorize(conn, color)} ", "#{cols}#{spine} "}
          end
        end

        # Renders *entry* to its tag-styled logical lines — empty while
        # folded under a collapsed ancestor.
        private def render_entry(entry : Entry) : Array(String)
          return [] of String if hidden_by_ancestor?(entry)

          body = body_lines(entry)
          hidden = 0
          if entry.collapsed && body.size > @collapse_threshold
            hidden = body.size - @collapse_threshold
            body = body[0, @collapse_threshold]
          end
          subtree_hidden = entry.collapsed ? entry.children.sum { |c| visible_line_count(c) } : 0

          first, cont =
            if entry.parent
              tree_lead entry
            else
              indent = "  " * entry.depth
              mark = colorize(self.class.prefix_glyph(entry.kind, entry.state), glyph_color(entry))
              case entry.kind
              in .tool_result?
                {"#{indent}  #{mark}  ", "#{indent}     "}
              in .diff?
                {indent, indent}
              in .prose?, .tool_call?, .todo?, .notice?, .thinking?, .error?
                {"#{indent}#{mark} ", "#{indent}  "}
              end
            end

          pre_styled = prose_body?(entry)
          out = Array(String).new(body.size + 1)
          body.each_with_index do |line, i|
            styled = pre_styled ? line : style_body_line(entry, line)
            out << "#{i.zero? ? first : cont}#{styled}"
          end
          if hidden + subtree_hidden > 0
            marker = "#{::Crysterm::Chat::Glyphs::ELLIPSIS} +#{hidden + subtree_hidden} lines (Ctrl+O)"
            out << "#{cont}#{colorize(marker, class_color(::Crysterm::Chat::Glyphs::CLASS_COLLAPSED))}"
          end
          out
        end

        # Per-line body styling: diff lines color by their leading `+`/`-`;
        # error, notice and thinking bodies take their class color;
        # everything else passes through (brace-escaped so bodies can't
        # inject tags).
        private def style_body_line(entry : Entry, line : String) : String
          esc = ::Crysterm::Formatting.escape_braces line
          case entry.kind
          in .diff?
            if line.starts_with?('+')
              colorize(esc, class_color(::Crysterm::Chat::Glyphs::CLASS_DIFF_ADD))
            elsif line.starts_with?('-')
              colorize(esc, class_color(::Crysterm::Chat::Glyphs::CLASS_DIFF_DEL))
            else
              esc
            end
          in .error?
            colorize(esc, class_color(::Crysterm::Chat::Glyphs::CLASS_ERROR))
          in .notice?
            colorize(esc, class_color(::Crysterm::Chat::Glyphs::CLASS_HINT))
          in .thinking?
            colorize(esc, class_color(::Crysterm::Chat::Glyphs::CLASS_THINKING))
          in .prose?, .tool_call?, .todo?, .tool_result?
            esc
          end
        end

        # First logical (fake) content line of the entry at *index* — O(1)
        # from the maintained `@starts` prefix sums.
        private def start_line_of(index : Int32) : Int32
          @starts[index]
        end

        # Total rendered (fake) line count — the running end of the prefix
        # sums.
        private def total_rendered_lines : Int32
          (@starts.last? || 0) + (@rendered.last?.try(&.size) || 0)
        end

        # Whether *prefix* equals the leading `prefix.size` elements of
        # *lines* — the streaming pure-growth test. An index walk, so the
        # per-tick check allocates nothing (no slice copy).
        private def prefix_of?(prefix : Array(String), lines : Array(String)) : Bool
          return false if lines.size < prefix.size
          prefix.size.times do |i|
            return false unless lines.unsafe_fetch(i) == prefix.unsafe_fetch(i)
          end
          true
        end

        # Re-renders just the entry at *index*, splicing its new lines over
        # the old ones in place. A changed line count shifts the `@starts` of
        # every later entry by the delta (styling-only re-renders — the
        # common theme/connector case — leave the sums untouched).
        private def rerender_entry(index : Int32) : Nil
          old = @rendered[index]
          lines = render_entry @entries[index]
          return if lines == old
          @rendered[index] = lines
          delta = lines.size - old.size
          unless delta.zero?
            (index + 1).upto(@starts.size - 1) { |i| @starts[i] += delta }
          end
          start = @starts[index]
          delete_line start, old.size unless old.empty?
          insert_line start, lines.join('\n') unless lines.empty?
        end
      end
    end
  end
end
