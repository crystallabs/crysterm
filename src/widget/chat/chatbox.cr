require "../box"
require "../../layout/vbox"
require "../../chat/completion"
require "../../chat/diff"
require "../../chat/glyphs"
require "../../chat/mode"
require "../../chat/task_registry"
require "./autocomplete"
require "./fleet_view"
require "./input"
require "./status_line"
require "./task_strip"
require "./transcript"

module Crysterm
  class Widget
    module Chat
      # The assembled Claude-CLI-style chat interface: a vertical composition
      # of `Transcript` (filling), `Input`, `TaskStrip` and `StatusLine`,
      # wired together with a shared `Chat::TaskRegistry`, a shared
      # `Chat::Completion::Registry` behind an attached `Autocomplete`, and a
      # rebindable composer keymap.
      #
      # ```
      # chat = Widget::Chat::ChatBox.new parent: window, width: "100%", height: "100%"
      # chat.on(Crysterm::Event::Submitted) do |e|
      #   chat.append_assistant "You said: #{e.value}"
      #   chat.idle
      # end
      # chat.focus_input
      # ```
      #
      # ### Wiring
      #
      # * `Input` `Event::Submitted` → the text is echoed into the transcript,
      #   the status line goes busy, and `Event::Submitted` is re-emitted on
      #   the composer for the embedding application. A leading-`/` submission
      #   naming a composer-local command (`/mode`, `/tasks`) executes locally
      #   instead (no busy, no re-emit).
      # * The `TaskRegistry` feeds both the strip (rows, auto show/hide,
      #   height) and the status line's `task_count`; a task first reaching a
      #   terminal state emits `Event::TaskCompleted` on the composer.
      # * Mode changes (`Shift+Tab`, `#mode=`, `/mode`) restyle the status
      #   badge, accent the input border in `Chat::Mode#color`, and emit
      #   `Event::ModeChanged`.
      # * Activating a strip row (Enter/double-click) summons the `FleetView`
      #   dashboard over the composer (`#fleet_on_activate?`); Escape on its
      #   roster (with nothing left to interrupt) dismisses it.
      #
      # ### Keymap
      #
      # A rebindable table (`#bind`/`#unbind`) of single-stroke `Tput::Key` →
      # `Command` bindings, dispatched from two seams:
      #
      # * an interceptor installed *ahead of the input's editing listener* —
      #   necessary because the reading input grabs the keyboard, so composer
      #   keys would otherwise never leave it; and
      # * a handler on the composer itself, reached by normal bubbling from
      #   any focused descendant (transcript, strip) that didn't consume the
      #   key.
      #
      # Defaults: `Shift+Tab` cycle mode, `Ctrl+B` toggle the task strip
      # (both directions — the composer-level binding is what re-shows a strip
      # hidden while focused, since a hidden widget receives no keys),
      # `Ctrl+O` expand/collapse the latest transcript entry, `Esc` interrupt
      # (busy → `Event::Cancelled` + idle; else clear the input), and
      # `Ctrl+K` stop-all — bound with `in_input: false` so the readline
      # kill-to-line-end keeps `Ctrl+K` while typing.
      #
      # Widgets keep their own local keys when focused (the strip's
      # `Ctrl+B`/`Ctrl+K`/`Esc`, the transcript's `Ctrl+O`): a key they accept
      # never reaches the composer tier, so nothing double-fires.
      # Excluded from the DOM-loader registry: self-populating composite
      # (see `Crysterm::DOM::Skip`).
      @[::Crysterm::DOM::Skip]
      class ChatBox < Box
        # The composer keymap's command vocabulary (see the class docs for the
        # default keys).
        enum Command
          # Advance the permission mode (`StatusLine#cycle_mode`).
          CycleMode
          # Hide/show the background-task strip.
          ToggleTasks
          # Expand/collapse the most recent collapsible transcript entry.
          ToggleCollapse
          # Cancel every unfinished task in the registry.
          StopAll
          # Interrupt: busy → `Event::Cancelled` + idle; else clear the input.
          Interrupt
        end

        # One keymap entry: the command a key runs, and whether it fires even
        # while typing in the input. Commands whose key the reading editor
        # itself claims (readline `Ctrl+K` = kill-to-line-end) set `in_input`
        # false so the editor keeps the key and the command fires only from
        # outside the input.
        record Binding, command : Command, in_input : Bool = true

        # The built-in `/` slash-command vocabulary registered with the shared
        # completion registry (name → menu description). `mode` and `tasks`
        # execute locally on submit; the rest reach the application through
        # `Event::Submitted` like any other text.
        SLASH_COMMANDS = {
          "help"   => "Show help",
          "model"  => "Switch model",
          "memory" => "Edit memory notes",
          "mode"   => "Cycle the permission mode",
          "tasks"  => "Toggle the background-task strip",
        }

        # (The child getters are nilable-backed `getter!`s, like `FleetView`'s:
        # the children are constructed with `parent: self`, i.e. after `self`
        # has already escaped the constructor.)

        # The transcript pane (fills the leftover height).
        getter! transcript : Transcript

        # Backing accessor of `#input` — `@input` is taken by the base
        # widget's wants-keyboard flag (`Widget#input?`).
        protected getter! input_box : ::Crysterm::Widget::Chat::Input

        # The chat prompt (auto-growing, bordered).
        def input : ::Crysterm::Widget::Chat::Input
          input_box
        end

        # The background-task strip under the input. Auto-shown while the
        # registry has tasks (unless toggled away), auto-hidden when empty.
        getter! task_strip : TaskStrip

        # The mode/hints/spinner status line at the bottom.
        getter! status_line : StatusLine

        # The trigger-key completion controller attached to the input. Its
        # `Autocomplete#on_accept` hook is left free for the application
        # (e.g. to switch input modes on a `!` completion).
        getter! autocomplete : Autocomplete

        # The shared background-task roster (strip, status count, fleet view).
        getter tasks : ::Crysterm::Chat::TaskRegistry

        # The shared trigger→candidates completion table.
        getter completions : ::Crysterm::Chat::Completion::Registry

        # The live keymap; mutate through `#bind`/`#unbind`.
        getter keymap = {} of ::Tput::Key => Binding

        # Whether the user toggled the task strip away (`Ctrl+B`). Distinct
        # from the strip's widget visibility, which is also `false` while the
        # registry is simply empty.
        getter? tasks_hidden = false

        # Most rows the task strip grows to before its interior scrolls.
        property strip_max_rows : Int32 = 4

        # Whether activating a strip row (Enter/double-click) summons the
        # `FleetView` dashboard.
        property? fleet_on_activate : Bool = true

        # Root directory the `@`-mention file provider indexes.
        property files_root : String = "."

        # Most entries the `@`-mention file index collects.
        property file_limit : Int32 = 500

        # The `#`-trigger completion candidates (memory notes); populate from
        # the application's memory store.
        property memory_notes = [] of String

        # The lazily-built fleet dashboard, or `nil` while never summoned.
        getter fleet : FleetView?

        # Cached `@`-mention candidates (`nil` until first queried); see
        # `#refresh_files`.
        @file_index : Array(::Crysterm::Chat::Completion::Item)?

        # Task id → finished flag at the last registry change, diffed to emit
        # `Event::TaskCompleted` exactly once per task.
        @task_finished = {} of Int32 => Bool

        # True while `#sync_tasks` itself shows/hides the strip, so the
        # Hide/Show subscriptions below only record *user* toggles (the
        # strip's own focused `Ctrl+B`).
        @strip_sync = false

        def initialize(
          tasks : ::Crysterm::Chat::TaskRegistry? = nil,
          completions : ::Crysterm::Chat::Completion::Registry? = nil,
          *,
          placeholder_text : String? = nil,
          builtin_completions : Bool = true,
          animate : Bool = true,
          files_root : String = ".",
          **box,
        )
          @tasks = tasks || ::Crysterm::Chat::TaskRegistry.new
          @completions = completions || ::Crysterm::Chat::Completion::Registry.new
          @files_root = files_root

          super **{keys: true, layout: ::Crysterm::Layout::VBox.new}.merge(box)

          # Children in VBox slot order. Only the transcript has no explicit
          # height, so it takes all the leftover space; the input manages its
          # own height (auto-grow), the strip's tracks the task count.
          @transcript = Transcript.new parent: self, keys: true
          input = @input_box = ::Crysterm::Widget::Chat::Input.new parent: self, placeholder_text: placeholder_text
          strip = @task_strip = TaskStrip.new @tasks, parent: self,
            keys: true, mouse: true, height: 1, animate: animate
          status = @status_line = StatusLine.new parent: self, height: 1

          install_default_keymap

          input.on(::Crysterm::Event::Submitted) { |e| handle_submit e.value }

          # The composer-key interceptor, ahead of the input's editing
          # listener. Installed BEFORE the autocomplete attaches: both
          # register `at_beginning` (last one in runs first), and the menu's
          # own key handling (Esc closes it, Up/Down move its highlight) must
          # win over the composer commands while the menu is open.
          input.on(::Crysterm::Event::KeyPress, at: ::EventHandler.at_beginning) do |e|
            dispatch_key e, in_input: true
          end

          ac = @autocomplete = Autocomplete.new @completions
          register_builtin_completions if builtin_completions
          ac.attach input

          # The bubble tier: keys a focused descendant (transcript, strip)
          # left unaccepted arrive here through the normal focus-chain walk.
          on(::Crysterm::Event::KeyPress) { |e| dispatch_key e, in_input: false }

          status.on(::Crysterm::Event::CurrentChanged) do |e|
            apply_mode ::Crysterm::Chat::Mode.from_value(e.index)
          end

          # Record user toggles made on the focused strip itself, so the next
          # registry change doesn't undo them. An ancestor-hide propagates
          # `Hide` without flipping the strip's own flag — the visibility
          # guards skip that case.
          strip.on(::Crysterm::Event::Hide) do
            @tasks_hidden = true unless @strip_sync || strip.visible?
          end
          strip.on(::Crysterm::Event::Show) do
            @tasks_hidden = false unless @strip_sync || strip.hidden?
          end

          strip.on(::Crysterm::Event::ItemActivated) do |e|
            if fleet_on_activate? && !strip.cancelling?
              @tasks[e.index]?.try { |task| open_fleet task }
            end
          end

          subs = ::Crysterm::Subscriptions.new
          subs.on(@tasks, ::Crysterm::Event::ListChanged) { sync_tasks }
          subs.auto_dispose(self) do
            subs.off
            Widget.destroy_satellite @fleet
            @fleet = nil
          end

          sync_tasks
        end

        # -- Keymap ------------------------------------------------------------

        # Binds *key* to *command* (replacing any previous binding of the
        # key). *in_input* — whether the command also fires while typing in
        # the input — see `Binding`.
        def bind(key : ::Tput::Key, command : Command, in_input : Bool = true) : Nil
          @keymap[key] = Binding.new command, in_input
        end

        # Removes the binding of *key*, if any.
        def unbind(key : ::Tput::Key) : Nil
          @keymap.delete key
        end

        # Executes *command* as if its key were pressed.
        def run_command(command : Command) : Nil
          case command
          in .cycle_mode?      then cycle_mode
          in .toggle_tasks?    then toggle_tasks
          in .toggle_collapse? then transcript.toggle_recent
          in .stop_all?        then @tasks.stop_all
          in .interrupt?       then interrupt
          end
        end

        # -- Transcript feeders (the embedding application's append surface) ---

        # Appends an entry of any *kind*; the general form behind the typed
        # helpers below. See `Transcript#append`.
        def append(kind : Transcript::Kind, text : String = "", *,
                   state : Transcript::State? = nil, depth : Int32 = 0,
                   collapsed : Bool = true,
                   parent : Transcript::Entry? = nil) : Transcript::Entry
          transcript.append kind, text,
            state: state, depth: depth, collapsed: collapsed, parent: parent
        end

        # Appends an assistant prose reply (markdown-rendered per
        # `Transcript#prose_markdown?`).
        def append_assistant(text : String) : Transcript::Entry
          append Transcript::Kind::Prose, text
        end

        # Appends a thinking/reasoning block.
        def append_thinking(text : String) : Transcript::Entry
          append Transcript::Kind::Thinking, text
        end

        # Appends a hint/notice line.
        def append_notice(text : String) : Transcript::Entry
          append Transcript::Kind::Notice, text
        end

        # Appends an error line.
        def append_error(text : String) : Transcript::Entry
          append Transcript::Kind::Error, text
        end

        # Appends a tool-call header entry; parent `#append_tool_result`s to it.
        def append_tool_call(text : String, *,
                             state : Transcript::State? = Transcript::State::Running) : Transcript::Entry
          append Transcript::Kind::ToolCall, text, state: state
        end

        # Appends a tool result under *parent* (its call).
        def append_tool_result(text : String, parent : Transcript::Entry, *,
                               state : Transcript::State? = nil) : Transcript::Entry
          append Transcript::Kind::ToolResult, text, state: state, parent: parent
        end

        # Appends a colored diff entry from *unified* diff text. *context*
        # trims hunk context (see `Chat::Diff.trim`). Plain `entry_text`, not
        # the tag-styled `format` — the transcript colors `+`/`-` lines
        # itself, and tag markup in a diff body would render literally.
        def append_diff(unified : String, *, context : Int32? = nil,
                        parent : Transcript::Entry? = nil) : Transcript::Entry
          append Transcript::Kind::Diff,
            ::Crysterm::Chat::Diff.entry_text(unified, context: context),
            parent: parent
        end

        # -- Busy / mode / tasks ----------------------------------------------

        # Enters the busy state (spinner + elapsed + interrupt hint on the
        # status line). See `StatusLine#busy`.
        def busy(text : String? = nil) : Nil
          status_line.busy text
        end

        # Leaves the busy state.
        def idle : Nil
          status_line.idle
        end

        # Whether the busy spinner is showing.
        def busy? : Bool
          status_line.busy?
        end

        # The current permission mode.
        def mode : ::Crysterm::Chat::Mode
          status_line.mode
        end

        # Sets the permission mode (badge, input border accent,
        # `Event::ModeChanged`); a no-op when unchanged.
        def mode=(mode : ::Crysterm::Chat::Mode) : ::Crysterm::Chat::Mode
          status_line.mode = mode
        end

        # Advances the permission mode, wrapping (the `Shift+Tab` action).
        def cycle_mode : ::Crysterm::Chat::Mode
          status_line.cycle_mode
        end

        # Registers a background task with the shared registry (which also
        # shows it on the strip and bumps the status count). Drive its
        # lifecycle through `#tasks` (`TaskRegistry#transition` etc.).
        def add_task(label : String,
                     kind : ::Crysterm::Chat::Task::Kind = :bash, *,
                     state : ::Crysterm::Chat::Task::State = :pending,
                     detail : String? = nil) : ::Crysterm::Chat::Task
          @tasks.add label, kind, state: state, detail: detail
        end

        # Flips the user-facing task-strip toggle (`Ctrl+B`). Showing is
        # effective only while the registry has tasks — an empty strip stays
        # hidden either way.
        def toggle_tasks : Nil
          @tasks_hidden = !@tasks_hidden
          sync_tasks
        end

        # The `Esc` action: busy → emit `Event::Cancelled` and go idle;
        # otherwise a non-empty input is cleared. (The interrupt reaches the
        # application as the `Cancelled` event; stopping its backend work is
        # its job.)
        def interrupt : Nil
          if busy?
            idle
            emit ::Crysterm::Event::Cancelled
          elsif !input.value.empty?
            input.clear
          end
        end

        # Focuses the chat input (which starts its read session).
        def focus_input : Nil
          input.focus
        end

        # Drops the cached `@`-mention file index so the next query re-scans
        # `#files_root`.
        def refresh_files : Nil
          @file_index = nil
        end

        # -- Fleet view --------------------------------------------------------

        # Summons the fleet dashboard over the composer — raised, frontmost
        # and focused — opening *task*'s transcript page when given. Created
        # lazily (as a window child, so it can overlay the composer without
        # entering its VBox), destroyed with the composer.
        def open_fleet(task : ::Crysterm::Chat::Task? = nil) : FleetView
          f = ensure_fleet
          place_fleet f
          f.show
          f.to_front
          task ? f.open(task) : f.roster.focus
          request_render
          f
        end

        # Dismisses the fleet dashboard and returns focus to the input.
        def close_fleet : Nil
          f = @fleet
          return unless f && f.visible?
          f.hide
          focus_input
          request_render
        end

        # -- Internals ---------------------------------------------------------

        private def install_default_keymap : Nil
          bind ::Tput::Key::ShiftTab, :cycle_mode
          bind ::Tput::Key::CtrlB, :toggle_tasks
          bind ::Tput::Key::CtrlO, :toggle_collapse
          bind ::Tput::Key::Escape, :interrupt
          # The reading editor claims Ctrl+K (readline kill-to-line-end), so
          # stop-all only fires from outside the input.
          bind ::Tput::Key::CtrlK, :stop_all, in_input: false
        end

        # The keymap dispatcher behind both seams (see the class docs).
        private def dispatch_key(e : ::Crysterm::Event::KeyPress, *, in_input : Bool) : Nil
          return if e.accepted?
          k = e.key
          return unless k
          binding = @keymap[k]?
          return unless binding
          return if in_input && !binding.in_input
          run_command binding.command
          e.accept
          if in_input
            # The input's read listener runs after this interceptor and does
            # not consult `#accepted?` — blank the key so it ignores it (the
            # `Autocomplete#consume` contract). Escape in particular must not
            # reach the editor, whose default ends the whole read session.
            e.key = nil
            e.char = '\u0000'
          end
        end

        # One hook for every registry change: strip visibility/height, status
        # count, and the completion diff behind `Event::TaskCompleted`.
        private def sync_tasks : Nil
          @strip_sync = true
          begin
            if @tasks_hidden || @tasks.empty?
              task_strip.hide
            else
              task_strip.height = Math.min(@tasks.size, @strip_max_rows)
              task_strip.show
            end
          ensure
            @strip_sync = false
          end
          status_line.task_count = @tasks.active_count
          check_completions
          request_render
        end

        # Emits `Event::TaskCompleted` for each task that finished since the
        # previous registry change. A task *added* already-finished never
        # fires (it was never observed unfinished).
        private def check_completions : Nil
          seen = @task_finished
          @tasks.each do |task|
            finished = task.finished?
            if finished && seen[task.id]? == false
              emit ::Crysterm::Event::TaskCompleted, task
            end
            seen[task.id] = finished
          end
          # In-place diff (this runs on every registry event), so entries of
          # removed tasks must be swept or they accrete forever. Ids are never
          # reused, so a stale entry can't corrupt the diff — the sweep only
          # needs to run when something actually left the registry.
          seen.reject! { |id, _| @tasks.find(id).nil? } if seen.size != @tasks.size
        end

        # Applies a mode change everywhere it shows: the input border accent
        # (`Chat::Mode#color`; `Normal` clears it) and the typed
        # `Event::ModeChanged`. The status badge is already restyled by the
        # emitting `StatusLine`.
        private def apply_mode(mode : ::Crysterm::Chat::Mode) : Nil
          input.state_style.border.fg = mode.color
          input.invalidate_frame_style
          input.request_render
          emit ::Crysterm::Event::ModeChanged, mode
        end

        # Echo + local slash execution + busy + re-emit (see the class docs).
        private def handle_submit(text : String) : Nil
          transcript.append Transcript::Kind::Prose, text
          return if text.starts_with?('/') && run_slash(text)
          busy
          emit ::Crysterm::Event::Submitted, text
        end

        # Executes a composer-local slash command; returns whether *text*
        # named one. Unknown commands return false and flow to the
        # application via `Event::Submitted`.
        private def run_slash(text : String) : Bool
          case text.lchop('/').split(' ', 2).first
          when "mode"  then cycle_mode
          when "tasks" then toggle_tasks
          else              return false
          end
          true
        end

        private def register_builtin_completions : Nil
          items = SLASH_COMMANDS.map do |name, desc|
            ::Crysterm::Chat::Completion::Item.new name, desc, :command
          end
          @completions.register '/', items
          @completions.register('@') { |_query| file_items }
          @completions.register('!') { |_query| bash_items }
          @completions.register('#') { |_query| memory_items }
        end

        # The `@`-mention candidates: a flat, capped `Dir.glob` walk under
        # `#files_root` (hidden files skipped by glob's default), built once
        # and cached — the provider runs per keystroke. Deliberately not
        # gitignore-aware; an application with a real file index can register
        # its own `@` provider instead (or on top).
        private def file_items : Array(::Crysterm::Chat::Completion::Item)
          @file_index ||= begin
            root = @files_root
            prefix = root.ends_with?('/') ? root : "#{root}/"
            out = [] of ::Crysterm::Chat::Completion::Item
            Dir.glob("#{prefix}**/*") do |path|
              break if out.size >= @file_limit
              out << ::Crysterm::Chat::Completion::Item.new path.lchop(prefix), "", :file
            end
            out
          end
        end

        # The `!`-trigger candidates: past `!`-prefixed submissions from the
        # input history (a stand-in shell history).
        private def bash_items : Array(::Crysterm::Chat::Completion::Item)
          input.history.compact_map do |past|
            next unless past.starts_with? '!'
            ::Crysterm::Chat::Completion::Item.new past.lchop('!').strip, "history", :bash
          end
        end

        # The `#`-trigger candidates, from `#memory_notes`.
        private def memory_items : Array(::Crysterm::Chat::Completion::Item)
          @memory_notes.map do |note|
            ::Crysterm::Chat::Completion::Item.new note, "", :memory
          end
        end

        private def ensure_fleet : FleetView
          @fleet ||= begin
            f = FleetView.new @tasks, parent: window, animate: task_strip.animate?
            f.hide
            # The roster's Escape with nothing left to interrupt falls through
            # to the stock item-view cancel — treat that as "leave the fleet".
            f.roster.on(::Crysterm::Event::ItemCancelled) { close_fleet }
            f
          end
        end

        # Sizes the fleet overlay to the composer's footprint (whole window
        # before a first layout resolves it).
        private def place_fleet(f : FleetView) : Nil
          f.left = aleft
          f.top = atop
          f.width = awidth
          f.height = aheight
        rescue
          f.left = 0
          f.top = 0
          f.width = "100%"
          f.height = "100%"
        end
      end
    end
  end
end
