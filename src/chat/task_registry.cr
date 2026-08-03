require "../reactive/observable_list"
require "./glyphs"

module Crysterm
  module Chat
    # One unit of background work surfaced in the chat UI: a background shell
    # command, a spawned sub-agent, or a queued follow-up.
    #
    # Plain mutable data — a `Task` emits nothing on its own. All change
    # notification is routed through the owning `TaskRegistry`
    # (`#update`/`#transition`), whose granular `Event::ListChanged` reaches
    # every bound view.
    class Task
      # What kind of work the task is.
      enum Kind
        Bash
        Agent
        Queued
      end

      # Lifecycle state of a task — the shared `Chat::State`, so tasks,
      # transcript entries and every view of them speak one state
      # vocabulary (glyphs/colors resolve through `Chat::Glyphs`).
      alias State = ::Crysterm::Chat::State

      # Registry-assigned, unique within one registry, never reused.
      getter id : Int32
      property label : String
      property kind : Kind
      property state : State
      # Exit status of a finished shell task; `nil` while unfinished or when
      # not applicable.
      property exit_code : Int32?
      # Free-form extra shown after the label (current step, elapsed time, …).
      property detail : String?

      def initialize(@id : Int32, @label : String, @kind : Kind = Kind::Bash, *,
                     @state : State = State::Pending, @exit_code : Int32? = nil,
                     @detail : String? = nil)
      end

      # Whether `#state` is terminal (see `State#finished?`).
      def finished? : Bool
        @state.finished?
      end
    end

    # The observable roster of background tasks the chat UI binds to (the
    # inline `Widget::Chat::TaskStrip`; any other dashboard can bind the same
    # registry — one model, many views).
    #
    # Mutating a `Task`'s fields directly does not notify; route changes
    # through `#update`/`#transition`/`#touch` so bound views repaint the
    # task's row.
    class TaskRegistry < Reactive::ObservableList(Task)
      # Monotonic id source.
      @next_id = 0

      # Task id → row memo behind `#find`/`#index_of` (and thus `#touch`,
      # which per-frame spinner/detail updates hammer). Kept honest by
      # `#emit_change`: an `Update` repairs the changed row's entry in place;
      # structural ops shift rows, so the memo is dropped and rebuilt lazily
      # (`nil` = stale).
      @rows : Hash(Int32, Int32)?

      # Creates a task, appends it (one `Insert`) and returns it.
      def add(label : String, kind : Task::Kind = Task::Kind::Bash, *,
              state : Task::State = Task::State::Pending,
              detail : String? = nil) : Task
        id = (@next_id += 1)
        task = Task.new(id, label, kind, state: state, detail: detail)
        push task
        task
      end

      # The task with *id*, or `nil`. O(1) via the row memo.
      def find(id : Int32) : Task?
        row_of(id).try { |i| self[i] }
      end

      # Row of *task* (by identity), or `nil` when not registered. O(1) via
      # the row memo; a duplicate-id roster (never produced by `#add`, whose
      # ids are unique) degrades to a linear scan rather than misreporting.
      def index_of(task : Task) : Int32?
        if i = row_of(task.id)
          return i if self[i].same?(task)
        end
        each_with_index { |t, j| return j if t.same?(task) }
        nil
      end

      # Yields *task* for mutation, then emits its row `Update` (via `#touch`)
      # so bound views repaint it. Returns whether the task was found.
      def update(task : Task, & : Task ->) : Bool
        yield task
        touch task
      end

      # Emits the row `Update` for *task* after an out-of-band mutation.
      # Returns whether the task was found.
      def touch(task : Task) : Bool
        i = index_of(task)
        return false unless i
        self[i] = task
        true
      end

      # Moves *task* to *state*, recording *exit_code* when given, and
      # notifies. The task keeps its row; completion surfaces to observers as
      # the row's `Update` (a dedicated completion event can layer on top).
      def transition(task : Task, state : Task::State,
                     exit_code : Int32? = nil) : Task
        task.state = state
        task.exit_code = exit_code unless exit_code.nil?
        touch task
        task
      end

      # Cancels every unfinished task — the Ctrl+K "stop all agents and
      # background work" action. Coalesced: the tasks mutate in place and a
      # single `Reset` `ListChanged` follows (none at all when nothing was
      # unfinished), so N cancellations cost each observer one rebuild
      # instead of N per-row fan-outs.
      def stop_all : Nil
        changed = false
        each do |t|
          next if t.finished?
          t.state = Task::State::Cancelled
          changed = true
        end
        emit_change Reactive::ListOp::Reset, 0, 0 if changed
      end

      # Number of tasks currently running.
      def running_count : Int32
        count &.state.running?
      end

      # Number of unfinished (pending or running) tasks.
      def active_count : Int32
        count { |t| !t.finished? }
      end

      # Keeps the row memo honest before observers run: an `Update` repairs
      # the changed row's entry in place (indices don't move); structural ops
      # (`Insert`/`Remove`/`Reset`) shift rows, so the memo is dropped.
      private def emit_change(op : Reactive::ListOp, index : Int32, count : Int32) : Nil
        if h = @rows
          op.update? ? (h[self[index].id] = index) : (@rows = nil)
        end
        super
      end

      # The memoized row of *id*, verified against the live roster (a row
      # replaced wholesale via `#[]=` strands its old id's entry); `nil` when
      # *id* is not present.
      private def row_of(id : Int32) : Int32?
        h = (@rows ||= rebuild_rows)
        if i = h[id]?
          return i if (t = self[i]?) && t.id == id
          h = @rows = rebuild_rows
          h[id]?
        end
      end

      private def rebuild_rows : Hash(Int32, Int32)
        h = Hash(Int32, Int32).new(initial_capacity: size)
        each_with_index { |t, i| h[t.id] = i }
        h
      end
    end
  end
end
