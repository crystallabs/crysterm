module Crysterm
  module Mixin
    # Tracks `Action`s' `Event::Changed` signal on behalf of a host that presents
    # them (a `Widget::Menu`, `Widget::ToolBar`, …), so the host re-renders when
    # an action's display state (checked, text, enabled, visibility) is changed
    # from the outside — mirroring how a Qt widget tracks its `QAction`'s
    # `changed()` signal.
    #
    # The host calls `#watch_action` with the body to run on each change; this
    # mixin owns the per-action handler map, the Qt-style host association
    # (`Action#associate`/`#dissociate`), and the teardown loop. Its
    # `#unwatch_all_actions` (or `#unwatch_action` per action) must run in the
    # host's `#destroy` so no stale handler fires against a torn-down widget and
    # no dead widget lingers in `Action#associated_widgets`.
    module ActionWatcher
      # Per-action `Event::Changed` handler, kept by action so it can be removed
      # again (`#unwatch_action`/`#unwatch_all_actions`).
      @action_changed = {} of Action => ::Proc(::Crysterm::Event::Changed, ::Nil)

      # Associates *action* with this host and re-runs *on_change* whenever the
      # action's display state changes. Idempotent: re-watching an already-watched
      # action is a no-op (the first handler stays).
      def watch_action(action : Action, &on_change : ::Crysterm::Event::Changed ->) : Nil
        return if @action_changed.has_key? action
        action.associate self # Qt's QAction::associatedWidgets bookkeeping
        action.on ::Crysterm::Event::Changed, on_change
        @action_changed[action] = on_change
      end

      # Stops watching *action* (removing its handler if present) and dissociates
      # it from this host. Dissociates even a never-watched action, so a host that
      # associates extras itself (e.g. `Widget::Menu`'s separators) can route them
      # through this shared dissociate path.
      def unwatch_action(action : Action) : Nil
        if handler = @action_changed.delete action
          action.off ::Crysterm::Event::Changed, handler
        end
        action.dissociate self
      end

      # Removes every watched action's handler and association. Call from the
      # host's `#destroy`.
      def unwatch_all_actions : Nil
        @action_changed.each do |action, handler|
          action.off ::Crysterm::Event::Changed, handler
          action.dissociate self
        end
        @action_changed.clear
      end
    end
  end
end
