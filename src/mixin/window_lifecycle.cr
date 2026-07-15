module Crysterm
  module Mixin
    # The "install-on-`Attach` / uninstall-on-`Detach` / and-also-now" window
    # lifecycle, for a widget that needs a *live window* for something — a
    # window-level key accelerator, a render-fiber timer. The including widget
    # supplies what gets installed and torn down by overriding
    # `#on_attach_window` / `#on_detach_window`.
    #
    # Call `wire_window_lifecycle` from `initialize` after `super`. Pass
    # `destroy: true` to also tear down on `Event::Destroy` (a direct destroy
    # while still attached never emits `Detach`), and `also_now: false` to skip
    # the immediate install (for a widget whose per-item `add` installs its own
    # pieces, so there is nothing to install until items exist).
    #
    # Not usable by a widget whose teardown needs the *leaving* window from the
    # `Detach` payload: `window?` is already nil by then, and
    # `#on_detach_window` takes no argument. Those wire it up explicitly.
    module WindowLifecycle
      # (Re)installs whatever this widget needs a live window for. Overridden by
      # the including widget. Called on `Event::Attach` and — unless wired with
      # `also_now: false` — once immediately by `#wire_window_lifecycle`.
      private def on_attach_window : Nil
      end

      # Tears down what `#on_attach_window` installed. Overridden by the
      # including widget. Called on `Event::Detach`, and on `Event::Destroy`
      # when wired with `destroy: true`.
      private def on_detach_window : Nil
      end

      # Subscribes the attach/detach (and optional destroy) handlers, and —
      # unless *also_now* is false — invokes `#on_attach_window` immediately so a
      # widget built already on a window installs without waiting for an
      # `Attach` that already fired.
      private def wire_window_lifecycle(destroy = false, also_now = true) : Nil
        on(::Crysterm::Event::Attach) { on_attach_window }
        on(::Crysterm::Event::Detach) { on_detach_window }
        on(::Crysterm::Event::Destroy) { on_detach_window } if destroy
        on_attach_window if also_now
      end
    end
  end
end
