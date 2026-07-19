module Crysterm
  module Mixin
    # Key-shortcut sugar: `on_key('q', :escape) { ... }` binds a handler to
    # specific keys without hand-writing a `case` inside a generic
    # `Event::KeyPress` handler. Included by `Window` (window-global shortcuts;
    # runs after the focus walk, so a key consumed by the focused widget never
    # fires the shortcut) and `Widget` (fires only while the widget has focus,
    # since widgets receive key presses via the focus walk).
    #
    # For a shortcut shared between menus/toolbars — with enable/disable state,
    # chords, and focus contexts — use `Action` with `shortcut:` instead; this
    # is the lightweight single-handler form.
    module KeyShortcuts
      # Runs *block* whenever one of *keys* is pressed. Each key is a `Char`
      # (`'q'`), a `Tput::Key` member (`Crysterm::Key` is its project-wide
      # alias), or that member's `Symbol` shorthand (`:escape`, `:ctrl_q`).
      # An unknown symbol raises immediately, at registration.
      #
      # A press already `#accept`ed (typed into a reading widget, consumed by a
      # more specific handler) does not fire. A firing press is `#accept`ed
      # *before* *block* runs, so it stops propagating even if *block* tears
      # the surface down.
      def on_key(*keys : Char | ::Tput::Key | Symbol, &block : ::Crysterm::Event::KeyPress ->)
        resolved = keys.map do |k|
          k.is_a?(Symbol) ? ::Tput::Key.parse(k.to_s.camelcase) : k
        end
        on(::Crysterm::Event::KeyPress) do |e|
          next if e.accepted?
          hit = resolved.any? do |k|
            case k
            in Char        then e.char == k
            in ::Tput::Key then e.key == k
            end
          end
          next unless hit
          e.accept
          block.call e
        end
      end
    end
  end
end
