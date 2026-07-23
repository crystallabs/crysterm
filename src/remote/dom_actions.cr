module Crysterm
  module DOM
    # Subscribes every `on*` action binding declared in a window's widget tree
    # (e.g. `onclick="save"`, `onsubmit="send"`) and invokes `handler` when the
    # corresponding event fires.
    #
    # The handler receives `(widget, event_name, action, value)`, where `value`
    # is the event's payload when meaningful (a `Submitted`'s text, a `ItemSelected`'s
    # index) and `nil` otherwise.
    #
    # `wired`, when given, tracks each `(widget, event)` binding's *current
    # action* plus its detacher, keyed by "uid:event". This must be re-run on
    # every `append`/`remove`/`setAttribute`, so without dedup bindings would fire
    # 2x, 3x, … per event. It dedups *by action*: an unchanged action is left
    # alone, a changed one detaches the stale binding and wires the new one.
    def self.each_binding(window : Window, wired : Hash(String, Tuple(String, Proc(Nil)))? = nil,
                          &handler : Widget, String, String, String? ->) : Nil
      # Keys still present in the tree this pass. Afterwards every *wired* key not
      # seen had its binding removed (its `on*` attribute cleared / its widget
      # gone), so its stale subscription is detached — otherwise a removed action
      # keeps firing forever, since iterating `dom_events` alone never revisits a
      # vanished binding.
      seen = Set(String).new
      window.children.each do |top|
        top.self_and_each_descendant do |widget|
          widget.dom_events.each do |event_name, action|
            if wired
              key = "#{widget.uid}:#{event_name}"
              seen << key
              if existing = wired[key]?
                next if existing[0] == action # same action already wired
                existing[1].call              # action changed: detach the stale binding
              end
              detacher = subscribe_binding widget, event_name, action, handler
              wired[key] = {action, detacher} if detacher
            else
              subscribe_binding widget, event_name, action, handler
            end
          end
        end
      end
      if wired
        wired.reject! do |key, entry|
          next false if seen.includes? key
          entry[1].call # binding removed since last pass: detach and drop it
          true
        end
      end
    end

    # Wires `event_name` on `widget`, invoking `handler` with the bound `action`.
    # Returns the detacher from `on_widget_event` (or `nil` for an unknown event
    # name) so a caller can later replace or remove this exact binding.
    private def self.subscribe_binding(widget : Widget, event_name : String, action : String,
                                       handler : Widget, String, String, String? ->) : Proc(Nil)?
      on_widget_event(widget, event_name) do |type, value|
        handler.call widget, type, action, value
      end
    end

    # The event names `on_widget_event` knows how to wire. Any other name wires
    # nothing, so callers can reject it up front rather than claiming a
    # subscription that will never fire.
    def self.known_event?(event_name : String) : Bool
      case event_name
      when "click", "press", "submit", "focus", "blur", "select", "change"
        true
      else
        false
      end
    end

    # Maps a layout event name (`"click"`, `"submit"`, `"select"`, …) to the
    # concrete `Event` class and subscribes to it, yielding `(canonical_type,
    # value)` when it fires — `value` carries the event's payload or `nil`.
    #
    # Returns a detacher `Proc` that removes exactly this handler, or `nil` for
    # an unknown event name (nothing was wired).
    def self.on_widget_event(widget : Widget, event_name : String, &block : String, String? ->) : Proc(Nil)?
      case event_name
      when "click", "press"
        # `Event::Pressed` is emitted only by `AbstractButton`, for both mouse click
        # and keyboard activation, so a button's `onclick` reacts to either, like
        # a browser button. Other widgets never emit `Pressed` and aren't even
        # hit-tested for it, so they bind `Event::Click` instead, which the window
        # emits on a mouse press over any hit-tested widget; registering it also
        # makes the widget mouse-responsive.
        if widget.is_a?(::Crysterm::Widget::AbstractButton)
          h = widget.on(::Crysterm::Event::Pressed) { block.call "press", nil }
          -> { widget.off(::Crysterm::Event::Pressed, h); nil }
        else
          h = widget.on(::Crysterm::Event::Click) { block.call "click", nil }
          -> { widget.off(::Crysterm::Event::Click, h); nil }
        end
      when "submit"
        h = widget.on(::Crysterm::Event::Submitted) { |e| block.call "submit", e.value }
        -> { widget.off(::Crysterm::Event::Submitted, h); nil }
      when "focus"
        h = widget.on(::Crysterm::Event::FocusIn) { block.call "focus", nil }
        -> { widget.off(::Crysterm::Event::FocusIn, h); nil }
      when "blur"
        h = widget.on(::Crysterm::Event::FocusOut) { block.call "blur", nil }
        -> { widget.off(::Crysterm::Event::FocusOut, h); nil }
      when "select", "change"
        h = widget.on(::Crysterm::Event::ItemSelected) { |e| block.call event_name, e.index.to_s }
        -> { widget.off(::Crysterm::Event::ItemSelected, h); nil }
      end
    end

    # Declarative action interpreter: lets simple behavior live entirely in the
    # HTML, so an app can run without a handler process. An action is
    # *declarative* when it names a built-in verb (optionally with
    # colon-separated arguments); anything else is a *named* action passed
    # through to an out-of-process handler.
    #
    # Verbs (in `on*` attribute values):
    #
    #   quit                              # tear the app down
    #   focus:<selector>                  # focus the first match
    #   add-class:<selector>:<class>      # classList.add  on every match
    #   remove-class:<selector>:<class>   # classList.remove
    #   toggle-class:<selector>:<class>   # classList.toggle
    #   set-content:<selector>:<text>     # set textual content
    #
    # `<selector>` is any `#resolve_selector` selector, or `@self` for the widget
    # that fired the event. Example: `<w-button onclick="toggle-class:#panel:open">`.
    module Actions
      # Is `action` a built-in verb (vs. a named action for a handler)?
      def self.declarative?(action : String) : Bool
        action == "quit" || action.includes?(':')
      end

      # Executes a declarative verb. Returns true if it was handled. `on_quit`,
      # when given, is invoked for `quit` (so a host can unwind cleanly) instead
      # of destroying the window directly.
      def self.run(action : String, source : Widget, window : Window, on_quit : Proc(Nil)? = nil) : Bool
        verb, _, rest = action.partition(':')
        case verb
        when "quit"
          on_quit ? on_quit.call : window.destroy
        when "focus"
          targets(rest, source, window).each &.focus
        when "add-class", "remove-class", "toggle-class"
          # Split the class token off the *right*: the class name is colon-free,
          # but a target selector legitimately contains `:` (a pseudo-class, e.g.
          # `.tab:hover`). A left split would strip the selector's own colons.
          sel, _, klass = rest.rpartition(':')
          targets(sel, source, window).each do |w|
            case verb
            when "add-class"    then w.add_css_class klass
            when "remove-class" then w.remove_css_class klass
            when "toggle-class" then w.toggle_css_class klass
            end
          end
        when "set-content"
          sel, text = split_selector_arg(rest)
          targets(sel, source, window).each &.set_content(text)
        else
          return false
        end
        window.render
        true
      end

      private def self.targets(selector : String, source : Widget, window : Window) : Array(Widget)
        case selector
        when "", "@self" then [source]
        else                  window.resolve_selector selector
        end
      end

      # Splits a `<selector>:<arg>` verb argument at the boundary between the
      # selector and its free-text argument. Unlike the class verbs (which
      # `rpartition` at the *last* colon, since their argument is a colon-free
      # class name), a verb whose argument can itself contain colons — e.g.
      # `set-content`'s text — can't use a fixed side split: the selector may
      # legitimately contain `:` too (a pseudo-class, e.g. `.tab:hover`,
      # `:nth-child(2)`).
      #
      # So this walks `rest` colon-by-colon, greedily extending the selector
      # prefix while it stays a compilable selector (the same validity check
      # `resolve_selector` uses), and stops at the first extension that fails
      # to compile — that colon is the selector/argument boundary. The first
      # segment is never itself compile-checked (so `@self` and the bare/empty
      # selector are unaffected); only extensions past the first colon are
      # probed. If every segment compiles, the whole string is the selector
      # and the argument is `""`.
      #
      # This is inherently ambiguous when the argument text itself happens to
      # be a compilable pseudo-class name right after a valid selector (e.g.
      # `set-content:#msg:empty` greedily reads as selector `#msg:empty` with
      # empty text) — unavoidable in a colon-delimited grammar. A verb that
      # needs to allow that should take a dedicated, unambiguous form instead.
      private def self.split_selector_arg(rest : String) : {String, String}
        parts = rest.split(':')
        return {rest, ""} if parts.size <= 1
        sel = parts[0]
        parts[1..].each_with_index do |part, i|
          candidate = "#{sel}:#{part}"
          compiled = (::CSS.compile(CSS::Selectors.expand_types(candidate)) rescue nil)
          if compiled
            sel = candidate
          else
            return {sel, parts[(i + 1)..].join(':')}
          end
        end
        {sel, ""}
      end
    end
  end

  class Window
    # Each declarative `on*` binding's current action plus its detacher, keyed
    # by "uid:event", passed to `DOM.each_binding` so a repeated
    # `wire_dom_actions` call (e.g. after appending a fragment) is idempotent
    # rather than double-subscribing every already-wired binding — mirroring
    # `HTTPBridge#rewire`'s `@declarative_wired`.
    @dom_actions_wired = {} of String => Tuple(String, Proc(Nil))
    # The `on_quit` from the most recent `wire_dom_actions` call, read by the
    # binding block at fire time (like the bridge's `@on_quit`) so a later call
    # with a different `on_quit` takes effect even for bindings left unchanged
    # (and thus not re-wired) by `each_binding`'s dedup.
    @dom_actions_on_quit : Proc(Nil)? = nil

    # Wires declarative `on*` actions in the loaded tree so simple apps need no
    # handler process. Named actions are ignored here — the HTTP bridge handles
    # those. `on_quit` lets a host unwind cleanly on `quit`.
    #
    # Safe to call repeatedly (e.g. after `DOM.load`/`load_layout` appends a
    # fragment onto an existing page): the persistent wired map dedups by
    # `(widget, event)`, so an unchanged binding is left alone rather than
    # re-subscribed.
    def wire_dom_actions(on_quit : Proc(Nil)? = nil) : Nil
      @dom_actions_on_quit = on_quit
      DOM.each_binding(self, @dom_actions_wired) do |widget, _type, action, _value|
        DOM::Actions.run(action, widget, self, @dom_actions_on_quit) if DOM::Actions.declarative?(action)
      end
    end
  end
end
