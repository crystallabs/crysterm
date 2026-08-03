require "./task_strip"
require "./transcript"
require "../stacked_widget"
require "../box"
require "../../chat/glyphs"
require "../../chat/task_registry"

module Crysterm
  class Widget
    module Chat
      # The fleet dashboard: a full-pane view of concurrent sub-agents and
      # background tasks, bound to the same `Crysterm::Chat::TaskRegistry`
      # the inline `TaskStrip` summarizes — one model, many views. Where the
      # strip is the at-a-glance readout under the chat input, the fleet view
      # gives every task a *detached context*: its own persistent
      # `Transcript` page, receiving output and keeping its scroll/collapse
      # state while hidden, raised on demand.
      #
      # Layout: a one-row header (`Fleet · N agents · R running · A active ·
      # peak P`), a task roster down the left (a `TaskStrip`, so the live
      # state glyphs, spinner and Ctrl+K/Esc task actions come along), and a
      # `StackedWidget` of per-task transcript pages filling the rest.
      #
      # Wiring:
      #
      # * Moving the roster selection raises the selected task's transcript
      #   page (created lazily on first show).
      # * `Enter` on the roster — or a click on the already-selected row —
      #   *opens* the task: raises its page and moves focus into the
      #   transcript, for scrolling and `Ctrl+O` collapse toggling.
      # * `Esc` inside a transcript hands focus back to the roster. (On the
      #   roster itself, `Esc` keeps its `TaskStrip` meaning: interrupt the
      #   selected task.)
      # * A task removed from the registry has its context destroyed; a task
      #   that merely *finished* keeps its transcript readable.
      #
      # Feed a context from the backend with `#transcript_for`, which returns
      # the task's transcript whether or not it is visible:
      #
      # ```
      # fleet = Widget::Chat::FleetView.new registry, parent: window
      # task = registry.add "explorer", Crysterm::Chat::Task::Kind::Agent
      # fleet.transcript_for(task).append Widget::Chat::Transcript::Kind::Prose, "starting…"
      # ```
      # Excluded from the DOM-loader registry: self-populating composite
      # (see `Crysterm::DOM::Skip`).
      @[::Crysterm::DOM::Skip]
      class FleetView < Box
        # The bound task roster model. Shared, not owned: any number of other
        # views (an inline `TaskStrip`, another fleet) may bind the same
        # registry.
        getter registry : ::Crysterm::Chat::TaskRegistry

        # The one-row summary bar across the top.
        getter! header : Box

        # The task roster down the left edge. (Its `TaskStrip#cancelling?`
        # latch is what lets the `ItemActivated` wiring below ignore the
        # activation the stock item-view cancel emits alongside
        # `ItemCancelled` — without it, cancelling a row would steal focus
        # into its page.)
        getter! roster : TaskStrip

        # The per-task transcript pages (plus the placeholder page shown when
        # no task is selected).
        getter! pages : StackedWidget

        # The page shown while the registry is empty or nothing maps to a
        # context.
        getter! placeholder : Box

        # Highest `TaskRegistry#running_count` observed over this view's
        # lifetime (the "peak concurrency" readout in the header).
        getter peak_running : Int32 = 0

        # Task id → its transcript page. Keyed by id, not `Task`, so lookup
        # never depends on the task still being registered.
        @contexts = {} of Int32 => Transcript

        def initialize(registry : ::Crysterm::Chat::TaskRegistry? = nil, *,
                       roster_width : Int32 = 30, animate : Bool = true, **box)
          @registry = registry || ::Crysterm::Chat::TaskRegistry.new
          super **box

          @header = Box.new parent: self,
            top: 0, left: 0, right: 0, height: 1, parse_tags: true
          @roster = TaskStrip.new @registry, parent: self,
            top: 1, left: 0, bottom: 0, width: roster_width,
            animate: animate, keys: true, mouse: true
          @pages = StackedWidget.new parent: self,
            top: 1, left: roster_width, right: 0, bottom: 0

          ph = Box.new content: "No task selected#{::Crysterm::Chat::Glyphs::SEP}" \
                                "agents and background tasks appear in the roster; " \
                                "Enter opens one"
          @placeholder = ph
          pages.add_widget ph

          roster.on(::Crysterm::Event::ItemSelected) do |e|
            show_task @registry[e.index]?
          end
          roster.on(::Crysterm::Event::ItemActivated) do |e|
            next if roster.cancelling?
            @registry[e.index]?.try { |task| open task }
          end

          subs = ::Crysterm::Subscriptions.new
          subs.on(@registry, ::Crysterm::Event::ListChanged) { on_registry_changed }
          subs.auto_dispose(self) { subs.off }

          on_registry_changed
        end

        # The transcript page of *task*'s detached context, created on first
        # use. The context persists — collecting appends and keeping its
        # scroll/collapse state — until the task leaves the registry, whether
        # or not its page is the visible one.
        def transcript_for(task : ::Crysterm::Chat::Task) : Transcript
          @contexts[task.id] ||= build_context
        end

        # The already-created context of *task*, or `nil` — never creates one
        # (unlike `#transcript_for`).
        def context?(task : ::Crysterm::Chat::Task) : Transcript?
          @contexts[task.id]?
        end

        # The visible page as a transcript, or `nil` on the placeholder.
        def current_transcript : Transcript?
          pages.current_widget.as? Transcript
        end

        # The task whose context page is currently raised, or `nil` (the
        # placeholder, or a task since removed from the registry).
        def current_task : ::Crysterm::Chat::Task?
          cur = current_transcript
          return unless cur
          @contexts.each do |id, transcript|
            return @registry.find(id) if transcript.same?(cur)
          end
          nil
        end

        # Opens *task*: selects its roster row, raises its transcript page
        # and moves focus into the transcript (the `Enter`-on-the-roster
        # action). Returns the transcript.
        def open(task : ::Crysterm::Chat::Task) : Transcript
          @registry.index_of(task).try { |i| roster.current_index = i }
          transcript = transcript_for task
          pages.current_widget = transcript
          transcript.focus
          transcript
        end

        # Raises *task*'s context page — or the placeholder for `nil` —
        # without touching focus or the roster selection.
        def show_task(task : ::Crysterm::Chat::Task?) : Nil
          pages.current_widget = task ? transcript_for(task) : placeholder
        end

        # A fresh, hidden transcript page wired into the stack: `Esc` inside
        # it hands focus back to the roster.
        private def build_context : Transcript
          transcript = Transcript.new keys: true
          transcript.on(::Crysterm::Event::KeyPress) do |e|
            if e.key == ::Tput::Key::Escape && !e.accepted?
              roster.focus
              e.accept
            end
          end
          pages.add_widget transcript
          transcript
        end

        # One hook for every registry change: drops contexts of removed
        # tasks, re-points the visible page at the roster's selection and
        # repaints the header (whose single registry walk also records peak
        # concurrency).
        private def on_registry_changed : Nil
          sweep_contexts
          show_task @registry[roster.current_index]?
          refresh_header
        end

        # Destroys the context of every task no longer in the registry. (The
        # stack's `remove` override keeps a valid page raised; the follow-up
        # `#show_task` in `#on_registry_changed` then re-points it at the
        # roster's selection.)
        private def sweep_contexts : Nil
          @contexts.reject! do |id, transcript|
            next false if @registry.find id
            transcript.destroy
            true
          end
        end

        # Rebuilds the header readout — agent count, running/active counts
        # and the lifetime peak, `·`-separated — accumulating all three
        # counts (and the peak high-water mark) in one registry pass: this
        # runs on every registry event.
        private def refresh_header : Nil
          agents = running = active = 0
          @registry.each do |t|
            agents += 1 if t.kind.agent?
            running += 1 if t.state.running?
            active += 1 unless t.finished?
          end
          @peak_running = running if running > @peak_running
          sep = ::Crysterm::Chat::Glyphs::SEP
          content = String.build do |io|
            io << "{bold}Fleet{/bold}" << sep
            io << agents << " agent"
            io << 's' if agents != 1
            io << sep << running << " running"
            io << sep << active << " active"
            io << sep << "peak " << @peak_running
          end
          header.set_content content
        end
      end
    end
  end
end
