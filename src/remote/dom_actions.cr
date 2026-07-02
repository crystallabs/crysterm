module Crysterm
  module DOM
    # Subscribes every `on*` action binding declared in a window's widget tree
    # (e.g. `onclick="save"`, `onsubmit="send"`) and invokes `handler` when the
    # corresponding event fires. Shared by the standalone declarative path and
    # the HTTP bridge so the event-name -> `Event` class mapping lives in one
    # place.
    #
    # The handler receives `(widget, event_name, action, value)` where `value`
    # is the event's payload when meaningful (a `Submit`'s text, a `SelectItem`'s
    # index) and `nil` otherwise.
    # `seen`, when given, dedups subscriptions across repeated calls: each
    # `(widget, event)` pair is wired at most once. The HTTP bridge re-runs this
    # on every `append`/`remove`, so without it bindings would fire 2x, 3x, ...
    # per event.
    def self.each_binding(window : Window, seen : Set(String)? = nil,
                          &handler : Widget, String, String, String? ->) : Nil
      window.children.each do |top|
        top.self_and_each_descendant do |widget|
          widget.dom_events.each do |event_name, action|
            if seen
              next unless seen.add? "#{widget.uid}:#{event_name}"
            end
            subscribe_binding widget, event_name, action, handler
          end
        end
      end
    end

    private def self.subscribe_binding(widget : Widget, event_name : String, action : String,
                                       handler : Widget, String, String, String? ->) : Nil
      on_widget_event(widget, event_name) do |type, value|
        handler.call widget, type, action, value
      end
    end

    # The event names `on_widget_event` knows how to wire. Any other name wires
    # nothing, so callers (e.g. the bridge's `subscribe`) can reject it up front
    # rather than claiming a subscription that will never fire.
    def self.known_event?(event_name : String) : Bool
      case event_name
      when "click", "press", "submit", "focus", "blur", "select", "change"
        true
      else
        false
      end
    end

    # Maps a layout event name (`"click"`, `"submit"`, `"select"`, ...) to the
    # concrete `Event` class and subscribes to it, yielding `(canonical_type,
    # value)` when it fires — `value` carries the event's payload or `nil`.
    # Shared by the action wiring here and the HTTP bridge's runtime
    # subscriptions.
    #
    # Returns a detacher `Proc` that removes exactly this handler (so the bridge
    # can honor `unsubscribe`), or `nil` for an unknown event name (nothing was
    # wired).
    def self.on_widget_event(widget : Widget, event_name : String, &block : String, String? ->) : Proc(Nil)?
      case event_name
      when "click", "press"
        # `Event::Press` is emitted only by `Widget::AbstractButton#activate`,
        # firing for both mouse click and keyboard activation (Enter/Space) — so
        # a button's `onclick`/`"press"` reacts to either, like a browser button.
        # Other widgets never emit `Press`, and since `Widget#wants_mouse?`
        # doesn't count `Press` handlers, they wouldn't even be hit-tested. Bind
        # those to `Event::Click` instead, which the window emits on a mouse
        # press over any hit-tested widget; registering it also makes the widget
        # mouse-responsive.
        if widget.is_a?(::Crysterm::Widget::AbstractButton)
          h = widget.on(::Crysterm::Event::Press) { block.call "press", nil }
          -> { widget.off(::Crysterm::Event::Press, h); nil }
        else
          h = widget.on(::Crysterm::Event::Click) { block.call "click", nil }
          -> { widget.off(::Crysterm::Event::Click, h); nil }
        end
      when "submit"
        h = widget.on(::Crysterm::Event::Submit) { |e| block.call "submit", e.value }
        -> { widget.off(::Crysterm::Event::Submit, h); nil }
      when "focus"
        h = widget.on(::Crysterm::Event::Focus) { block.call "focus", nil }
        -> { widget.off(::Crysterm::Event::Focus, h); nil }
      when "blur"
        h = widget.on(::Crysterm::Event::Blur) { block.call "blur", nil }
        -> { widget.off(::Crysterm::Event::Blur, h); nil }
      when "select", "change"
        h = widget.on(::Crysterm::Event::SelectItem) { |e| block.call event_name, e.index.to_s }
        -> { widget.off(::Crysterm::Event::SelectItem, h); nil }
      else
        nil
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
          sel, _, text = rest.partition(':')
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
    end
  end

  class Window
    # Wires declarative `on*` actions in the loaded tree so simple apps need no
    # handler process. Named actions are ignored here — the HTTP bridge handles
    # those. `on_quit` lets a host unwind cleanly on `quit`.
    def wire_dom_actions(on_quit : Proc(Nil)? = nil) : Nil
      DOM.each_binding(self) do |widget, _type, action, _value|
        DOM::Actions.run(action, widget, self, on_quit) if DOM::Actions.declarative?(action)
      end
    end
  end
end
