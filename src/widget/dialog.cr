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
    # Owns the family's shared **result protocol** (`#result` / `#done` /
    # `#accept` / `#reject`, the `Accepted`/`Rejected`/`Finished` signals), the
    # modal Enter/Escape accelerator, and modality (`#modal?`). Concrete dialogs
    # add their own presentation and a block-based convenience form
    # (`Message#display`, `Question#ask`, `Prompt#read_input`, `ColorDialog#pick`),
    # which is sugar over the same protocol — both always agree.
    abstract class Dialog < Box
      # ---- Result protocol (Qt's `QDialog`) ----------------------------------

      # The outcome of a dialog (Qt's `QDialog::DialogCode`). Qt's numbering is
      # kept verbatim — `Rejected == 0`, `Accepted == 1` — rather than invented:
      # `#done` takes a plain `Int32` like Qt's `done(int)` so a dialog can
      # return a richer application-defined code, and Qt's convention is the one
      # every such code is written against.
      enum Code
        Rejected = 0
        Accepted = 1
      end

      # The code the dialog closed with (Qt's `QDialog#result`). `Code::Rejected`
      # until `#done` (or `#accept`/`#reject`) runs, so a dialog dismissed
      # without an answer reads as rejected.
      getter result : Int32 = Code::Rejected.to_i

      # Whether the dialog closed affirmatively (`#result == Code::Accepted`).
      def accepted? : Bool
        @result == Code::Accepted.to_i
      end

      # Closes the dialog with *result* (Qt's `QDialog#done(int)`): records it,
      # hides the dialog, drops any modal grab, then signals — `Event::Accepted`
      # or `Event::Rejected` for the two standard codes (an application-defined
      # code emits neither), followed always by `Event::Finished`.
      #
      # This is the single funnel every close path goes through, so `#result`,
      # the signals and the block-based convenience forms can never disagree.
      def done(result : Int32) : Nil
        @result = result
        hide
        self.modal = false
        case result
        when Code::Accepted.to_i then emit ::Crysterm::Event::Accepted
        when Code::Rejected.to_i then emit ::Crysterm::Event::Rejected
        end
        emit ::Crysterm::Event::Finished, result
        request_render
        @finished.try &.send result
      end

      # :ditto:
      def done(code : Code) : Nil
        done code.to_i
      end

      # Whether the dialog holds the window's modal input grab: while set, only
      # this dialog (and its children) receive pointer input (Qt's
      # `QDialog#modal`). Applied on `#open`, released by `#done`.
      getter? modal : Bool = false

      # Sets `#modal`, taking/releasing the window grab. No-op while detached —
      # `#open` re-applies it once the dialog is on a window.
      def modal=(value : Bool) : Bool
        return value if @modal == value
        @modal = value
        window?.try { |w| value ? w.grab(self) : w.ungrab(self) }
        value
      end

      # Shows the dialog modally and returns **immediately** (Qt's
      # `QDialog#open`); the outcome arrives later on `Event::Finished` (or
      # `Accepted`/`Rejected`). This is the form to use from an event handler.
      def open : Nil
        @result = Code::Rejected.to_i
        show
        front!
        self.modal = true
        focus
        install_dialog_keys
        request_render
      end

      # Channel a blocking `#exec` parks on, created per call and dropped by the
      # `#done` that wakes it. Nil whenever no `#exec` is in flight.
      @finished : Channel(Int32)? = nil

      # Shows the dialog modally and **blocks the calling fiber** until it closes,
      # returning `#result` (Qt's `QDialog#exec`).
      #
      # NOTE Call this only from a fiber of your own (`spawn { … }`). Crysterm
      # reads input and renders on their own fibers, so blocking *those* — i.e.
      # calling `#exec` straight from an event handler — deadlocks the dialog:
      # nothing would be left to deliver the keypress that closes it. From a
      # handler use `#open` plus `Event::Finished` instead.
      def exec : Int32
        ch = @finished = Channel(Int32).new(1)
        open
        ch.receive
      ensure
        @finished = nil
      end

      # Dialogs are overlays: at the unstyled floor they carry a structural
      # border to separate from content behind them. An active theme can
      # override/remove this via `Mixin::Style#floor_border?`.
      include Mixin::Overlay

      # ---- Modal key accelerator (FORMAL-WIDGETS B3.1 / B3.2) -----------------
      #
      # Centralizes the modal Enter/Escape accelerator shared by every dialog:
      # install a window-level `KeyPress` listener, remember the window so it can
      # be `off`'d even after detach, and route Enter→accept / Escape→reject. The
      # *mechanics* live here once; each dialog decides only *when* to install
      # (on open vs. on attach) and *whether* a given key applies (via
      # `#dialog_keys_active?`), plus what accept/reject do.

      # Window-level accelerator subscription. A `Subscription` captures the
      # window it was installed on, so teardown works from `Detach`/`Destroy`
      # where `window?` is already nil.
      @dialog_keys = ::Crysterm::Subscription.new

      # Installs the window-level Enter/Escape accelerator (idempotent).
      protected def install_dialog_keys : Nil
        # Drop any prior handler first, so a re-install — or an install attempted
        # while detached — can't leave a stale one behind.
        @dialog_keys.off
        return unless w = window?
        @dialog_keys.on(w, Crysterm::Event::KeyPress) { |e| dialog_key e }
      end

      # Removes the accelerator via the captured window (idempotent — safe to call
      # from both the normal close path and `#destroy`).
      protected def uninstall_dialog_keys : Nil
        @dialog_keys.off
      end

      # Default accelerator body: Enter accepts, Escape rejects. Runs only when
      # `#dialog_keys_active?` allows it, so a focused editor/button keeps the key
      # first. Subclasses tune the guard via `#dialog_keys_active?` and the
      # actions via `#accept`/`#reject`.
      protected def dialog_key(e : Crysterm::Event::KeyPress) : Nil
        # A focused dialog button (e.g. Cancel) may already have consumed this
        # Enter/Escape — don't also fire the window-level accelerator, or the
        # key double-acts (both Rejected AND Accepted). This makes `Wizard`'s
        # `dialog_keys_active? = !e.accepted?` override redundant, but harmless.
        return if e.accepted?
        return unless dialog_keys_active? e
        case e.key
        when Tput::Key::Enter  then accept; e.accept
        when Tput::Key::Escape then reject; e.accept
        end
        request_render if e.accepted?
      end

      # Whether the accelerator should act on *e*. Default: always. Overridden to
      # stand down while a field is focused (`ColorDialog`) or once the focused
      # widget already consumed the key (`Wizard`).
      protected def dialog_keys_active?(e : Crysterm::Event::KeyPress) : Bool
        true
      end

      # Affirmative gesture (Enter / Ok), mirroring Qt's `QDialog#accept`:
      # closes with `Code::Accepted`. Subclasses that override it to add their
      # own bookkeeping must still end up in `#done`, so the contract holds.
      def accept : Nil
        done Code::Accepted
      end

      # Negative gesture (Escape / Cancel), mirroring Qt's `QDialog#reject`:
      # closes with `Code::Rejected`. See `#accept` on overriding.
      def reject : Nil
        done Code::Rejected
      end

      # Drops the modal grab and the accelerator before teardown, so neither
      # outlives the dialog on the window (a modal grab that never lifts would
      # swallow every later click).
      def destroy
        self.modal = false
        uninstall_dialog_keys
        super
      end
    end
  end
end
