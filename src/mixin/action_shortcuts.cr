module Crysterm
  module Mixin
    # The window lifecycle for a widget that owns `Action`s whose keyboard
    # accelerators must live on the widget's window: install them on
    # `Event::Attached`, withdraw them on `Event::Detached`.
    #
    # This is the one shape `Mixin::WindowLifecycle` explicitly cannot serve
    # (see its docs): the teardown needs the window being *left*, and by the time
    # `Detached` fires `parent`/`window` are already nulled — so the departing
    # window must be taken from the event payload (`e.window`), never from
    # `window?`. Getting that wrong silently strands accelerators firing on a
    # window the host has left.
    #
    # An includer supplies the action set by overriding `#each_shortcut_action`
    # (always chaining `super`, so a host's own `Widget#add_action` actions keep
    # working alongside its presented ones), and calls `#wire_action_shortcuts`
    # once — from `initialize` for a host that always has actions, lazily for one
    # that usually has none. A host needing work done before each install (e.g.
    # `MenuBar` rehoming its pop-ups onto the new window) overrides
    # `#before_install_action_shortcuts`.
    module ActionShortcutHost
      # Yields every `Action` whose accelerator this host owns. The base
      # implementation yields nothing; `Widget` yields its `#actions`, and
      # presenting hosts (`ToolBar`, `MenuBar`) add theirs on top via `super`.
      private def each_shortcut_action(&_block : ::Crysterm::Action ->) : Nil
      end

      # Hook run at the start of every `#install_action_shortcuts`. No-op by
      # default.
      private def before_install_action_shortcuts : Nil
      end

      # Subscribes the attach/detach handlers. Call once.
      private def wire_action_shortcuts : Nil
        on(::Crysterm::Event::Attached) { install_action_shortcuts }
        # `window?` is already nil here — the window being left rides in the
        # event payload.
        on(::Crysterm::Event::Detached) { |e| uninstall_action_shortcuts e.window }
      end

      # Installs every owned action's accelerator on the host's window.
      # Idempotent; a no-op while detached.
      private def install_action_shortcuts : Nil
        before_install_action_shortcuts
        w = window? || return
        each_shortcut_action &.install_shortcut(w, self)
      end

      # Withdraws every owned action's accelerator from *w* — the window the host
      # is leaving, supplied via the `Detached` event payload (or `window?` when
      # called from a teardown that still has one).
      private def uninstall_action_shortcuts(w : ::Crysterm::Window?) : Nil
        return unless w
        each_shortcut_action &.uninstall_shortcut(w)
      end
    end
  end
end
