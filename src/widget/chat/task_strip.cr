require "../list"
require "../effect/animated"
require "../../chat/glyphs"
require "../../chat/task_registry"
require "../../formatting"
require "../../reactive/bind_items"

module Crysterm
  class Widget
    module Chat
      # The tasks/agents strip: a compact list of background work, one row per
      # `Crysterm::Chat::Task` — state glyph + label + state note — bound
      # reactively to a `Crysterm::Chat::TaskRegistry` and meant to sit
      # directly under the chat input.
      #
      # Rows patch row-by-row from the registry's granular
      # `Event::ListChanged` (via `Reactive.bind_items`): an added task
      # appends one row, a `TaskRegistry#transition` rewrites one row, a
      # removal drops one row.
      #
      # Keys (on the focused strip):
      #
      # * `Ctrl+B` — toggle the strip (hides it; re-showing is a job for a
      #   composer-level binding, since a hidden widget receives no keys).
      # * `Ctrl+K` — stop all: cancels every unfinished task in the registry.
      # * `Esc` — interrupt the selected task while it is still active;
      #   otherwise falls through to the stock item-view Escape.
      #
      # Running rows animate through `Crysterm::Chat::Glyphs::SPINNER_FRAMES`.
      # The frame clock (`Effect::Animated`) starts and stops itself as tasks
      # start/finish; `#step` is public, so a headless caller can advance
      # frames explicitly instead (`animate: false`).
      #
      # Row glyphs and colors resolve through the shared chat vocabulary
      # (`Crysterm::Chat::Glyphs.glyph_for`/`.state_class` → `#class_colors`,
      # seeded from `Glyphs::DEFAULT_CLASS_COLORS`), so strip rows and
      # transcript entries color a given state alike and `#set_class_color`
      # rethemes existing rows.
      class TaskStrip < List
        include Effect::Animated

        # The bound task roster; rows track it for the widget's lifetime.
        getter registry : ::Crysterm::Chat::TaskRegistry

        # Whether the frame clock self-starts while any task is running. When
        # false, drive the spinner explicitly with `#step`.
        property? animate : Bool

        # Index into `SPINNER_FRAMES`, shared by all running rows so they
        # animate in phase.
        @spinner_frame = 0

        # The per-widget class-name → color table row rendering resolves
        # task states against, seeded from the shared
        # `Crysterm::Chat::Glyphs::DEFAULT_CLASS_COLORS`. Mutate via
        # `#set_class_color` so existing rows repaint.
        getter class_colors : Hash(String, String) = ::Crysterm::Chat::Glyphs::DEFAULT_CLASS_COLORS.dup

        def initialize(registry : ::Crysterm::Chat::TaskRegistry? = nil, *,
                       animate : Bool = true, **list)
          @registry = registry || ::Crysterm::Chat::TaskRegistry.new
          @animate = animate
          super **list

          # The Claude-style sparkle spinner cadence (~200 ms), not the
          # `Effect::Animated` 70 ms default.
          self.interval = 0.2.seconds

          ::Crysterm::Reactive.bind_items(self, @registry) { |t| render_row t }
          subs = ::Crysterm::Subscriptions.new
          subs.on(@registry, ::Crysterm::Event::ListChanged) { sync_animation }
          subs.auto_dispose(self) { subs.off }
          sync_animation
        end

        # Advances the spinner one frame and rewrites the running rows
        # (`Effect::Animated`'s per-tick hook; call directly to drive the
        # animation from an external clock or a headless test).
        def step
          @spinner_frame &+= 1
          refresh_running_rows
        end

        # Overrides (or with `nil`, clears) the color of a styling class and
        # rewrites every row, so a theme change applies to existing tasks
        # (the strip-side mirror of `Transcript#set_class_color`).
        def set_class_color(name : String, color : String?) : Nil
          if color
            @class_colors[name] = color
          else
            @class_colors.delete name
          end
          @registry.each_with_index { |task, i| set_item i, render_row(task) }
        end

        # The row text for *task*: colored state glyph, brace-escaped label,
        # optional `· detail`, and a trailing state note (`queued`,
        # `running…`, `exit N`, `✓`/`✗`, `cancelled`). Glyph and color come
        # from the shared state vocabulary (running rows substitute the live
        # spinner frame).
        def render_row(task : ::Crysterm::Chat::Task) : String
          glyph = task.state.running? ? spinner_glyph : ::Crysterm::Chat::Glyphs.glyph_for(task.state)
          color = @class_colors[::Crysterm::Chat::Glyphs.state_class(task.state)]?
          note =
            case task.state
            in .pending? then "queued"
            in .running? then "running#{::Crysterm::Chat::Glyphs::ELLIPSIS}"
            in .ok?, .fail?
              (code = task.exit_code) ? "exit #{code}" : glyph
            in .cancelled? then "cancelled"
            end
          if color
            glyph = "{#{color}-fg}#{glyph}{/#{color}-fg}"
            note = "{#{color}-fg}#{note}{/#{color}-fg}"
          end
          String.build do |io|
            io << glyph << ' ' << ::Crysterm::Formatting.escape_braces(task.label)
            if detail = task.detail
              io << ::Crysterm::Chat::Glyphs::SEP
              io << ::Crysterm::Formatting.escape_braces(detail)
            end
            io << ' ' << note
          end
        end

        # Whether the keypress currently being dispatched is an Escape. Only
        # ever true inside an `#handle_key_press` dispatch.
        #
        # Needed because the stock item-view cancel (Escape on a settled row,
        # reached through this class's Escape fall-through) emits
        # `Event::ItemActivated` alongside `Event::ItemCancelled` — so an
        # activation subscriber (a fleet view raising a task page, a composer
        # summoning one) must gate on this latch, or cancelling a row would
        # also activate it.
        getter? cancelling = false

        # `Ctrl+B`/`Ctrl+K`/`Esc` (see the class doc); anything else keeps the
        # stock item-view keys. `Ctrl+B` deliberately shadows the item-view
        # page-up chord — the strip is a short list.
        def handle_key_press(e)
          @cancelling = e.key == ::Tput::Key::Escape
          case e.key
          when ::Tput::Key::CtrlB
            visible? ? hide : show
            e.accept
          when ::Tput::Key::CtrlK
            @registry.stop_all
            e.accept
            update!
          when ::Tput::Key::Escape
            if interrupt_current
              e.accept
              update!
            else
              super
            end
          else
            super
          end
        ensure
          @cancelling = false
        end

        # Cancels the selected row's task while it is still active. Returns
        # whether anything was interrupted.
        def interrupt_current : Bool
          task = @registry[current_index]?
          return false unless task && !task.finished?
          @registry.transition task, ::Crysterm::Chat::Task::State::Cancelled
          true
        end

        # The spinner frame the running rows currently show.
        private def spinner_glyph : String
          frames = ::Crysterm::Chat::Glyphs::SPINNER_FRAMES
          frames[@spinner_frame % frames.size]
        end

        # Rewrites every running row with the current spinner frame; settled
        # rows are left untouched.
        private def refresh_running_rows : Nil
          @registry.each_with_index do |task, i|
            set_item i, render_row(task) if task.state.running?
          end
        end

        # Starts/stops the frame clock to match "any task running".
        private def sync_animation : Nil
          return unless animate?
          if @registry.any? &.state.running?
            start unless running?
          else
            stop if running?
          end
        end
      end
    end
  end
end
