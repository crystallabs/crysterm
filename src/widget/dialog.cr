require "./box"

module Crysterm
  class Widget
    # Abstract base for the dialog family, modeled after Qt's `QDialog`.
    #
    # `ColorDialog`, `Message`, `Question`/`Prompt` and `Wizard` derive this,
    # mirroring Qt where every standard dialog is a `QDialog` subclass.
    # (`DialogButtonBox` does *not*: Qt's `QDialogButtonBox` is a plain
    # `QWidget`, so it stays a `Box`.)
    #
    # Thin grouping base over `Box` with no behavior of its own; gives the
    # family a shared type so a `Dialog { … }` selector matches every dialog.
    abstract class Dialog < Box
      # Dialogs are overlays: at the unstyled floor they carry a structural
      # border to separate from content behind them. An active theme can
      # override/remove this via `Mixin::Style#floor_border?`.
      include Mixin::Overlay

      # ---- Modal key accelerator (FORMAL-WIDGETS B3.1 / B3.2) -----------------
      #
      # Centralizes the modal Enter/Escape accelerator shared by every dialog:
      # install a window-level `KeyPress` listener, remember the window so it can
      # be `off`'d even after detach, and route Enter→accept / Escape→cancel. The
      # *mechanics* live here once; each dialog decides only *when* to install
      # (on open vs. on attach) and *whether* a given key applies (via
      # `#dialog_keys_active?`), plus what accept/cancel do.

      # Window-level accelerator handle + the window it was installed on, captured
      # so teardown works from `Detach`/`Destroy` where `window?` is already nil.
      @dialog_keys : Crysterm::Event::KeyPress::Wrapper?
      @dialog_keys_window : Window?

      # Installs the window-level Enter/Escape accelerator (idempotent).
      protected def install_dialog_keys : Nil
        uninstall_dialog_keys
        return unless w = window?
        @dialog_keys_window = w
        @dialog_keys = w.on(Crysterm::Event::KeyPress) { |e| dialog_key e }
      end

      # Removes the accelerator via the captured window (idempotent — safe to call
      # from both the normal close path and `#destroy`).
      protected def uninstall_dialog_keys : Nil
        if (h = @dialog_keys) && (w = @dialog_keys_window)
          w.off Crysterm::Event::KeyPress, h
        end
        @dialog_keys = nil
        @dialog_keys_window = nil
      end

      # Default accelerator body: Enter accepts, Escape cancels. Runs only when
      # `#dialog_keys_active?` allows it, so a focused editor/button keeps the key
      # first. Subclasses tune the guard via `#dialog_keys_active?` and the
      # actions via `#accept`/`#cancel`.
      protected def dialog_key(e : Crysterm::Event::KeyPress) : Nil
        # A focused dialog button (e.g. Cancel) may already have consumed this
        # Enter/Escape — don't also fire the window-level accelerator, or the
        # key double-acts (both Rejected AND Accepted). This makes `Wizard`'s
        # `dialog_keys_active? = !e.accepted?` override redundant, but harmless.
        return if e.accepted?
        return unless dialog_keys_active? e
        case e.key
        when Tput::Key::Enter  then accept; e.accept
        when Tput::Key::Escape then cancel; e.accept
        end
        request_render if e.accepted?
      end

      # Whether the accelerator should act on *e*. Default: always. Overridden to
      # stand down while a field is focused (`ColorDialog`) or once the focused
      # widget already consumed the key (`Wizard`).
      protected def dialog_keys_active?(e : Crysterm::Event::KeyPress) : Bool
        true
      end

      # Affirmative gesture (Enter / Ok), mirroring Qt's `QDialog#accept`.
      # No-op by default; concrete dialogs override it.
      def accept : Nil
      end

      # Negative gesture (Escape / Cancel), mirroring Qt's `QDialog#reject`.
      # No-op by default; concrete dialogs override it.
      def cancel : Nil
      end
    end
  end
end
