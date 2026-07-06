module Crysterm
  module Mixin
    # The "install-on-`Attach` / uninstall-on-`Detach` / and-also-now" window
    # lifecycle, extracted from the several widgets that each hand-rolled it.
    #
    # A widget that needs a *live window* for something — a window-level key
    # accelerator (`Widget::Wizard`, `Widget::SplashScreen`), a render-fiber
    # timer (`Widget::TabWidget`'s carousel) — must (re)install that thing every
    # time it lands on a window and tear it down every time it leaves, plus do
    # the install once immediately in case it was constructed already attached
    # (`parent:`/`window:`). The subscription plumbing for that triple is
    # identical everywhere; only *what* gets installed/torn down differs, so the
    # including widget supplies just that by overriding `#on_attach_window` /
    # `#on_detach_window`.
    #
    # Call `wire_window_lifecycle` from `initialize` after `super`. Pass
    # `destroy: true` to also tear down on `Event::Destroy` (a direct destroy
    # while still attached never emits `Detach`), and `also_now: false` to skip
    # the immediate install (for a widget whose per-item `add` installs its own
    # pieces, so there is nothing to install until items exist).
    #
    # Widgets whose teardown needs the *leaving* window from the `Detach`
    # payload (`window?` is already nil by then — e.g. `Widget::MenuBar`,
    # `Widget::ToolBar`) do **not** use this: their `#on_detach_window` couldn't
    # recover that window. They keep their own explicit wiring.
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
