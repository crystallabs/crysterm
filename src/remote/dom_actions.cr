module Crysterm
  module DOM
    # Subscribes every `on*` action binding declared in a screen's widget tree
    # (e.g. `onclick="save"`, `onsubmit="send"`) and invokes `handler` when the
    # corresponding event fires. Shared by the standalone declarative path and
    # the HTTP bridge so the event-name -> `Event` class mapping lives in one
    # place.
    #
    # The handler receives `(widget, event_name, action, value)` where `value`
    # is the event's payload when meaningful (a `Submit`'s text, a `SelectItem`'s
    # index) and `nil` otherwise.
    def self.each_binding(screen : Screen, &handler : Widget, String, String, String? ->) : Nil
      screen.children.each do |top|
        top.self_and_each_descendant do |widget|
          widget.dom_events.each do |event_name, action|
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

    # The single place that maps a layout event name (`"click"`, `"submit"`,
    # `"select"`, ...) to the concrete `Event` class and subscribes to it,
    # yielding `(canonical_type, value)` when it fires — `value` carries the
    # event's payload (a `Submit`'s text, a `SelectItem`'s index) or `nil`.
    # Shared by the action wiring here and the HTTP bridge's runtime
    # subscriptions so the mapping exists once. Unknown names are ignored.
    def self.on_widget_event(widget : Widget, event_name : String, &block : String, String? ->) : Nil
      case event_name
      when "click", "press"
        widget.on(::Crysterm::Event::Press) { block.call "press", nil }
      when "submit"
        widget.on(::Crysterm::Event::Submit) { |e| block.call "submit", e.value }
      when "focus"
        widget.on(::Crysterm::Event::Focus) { block.call "focus", nil }
      when "blur"
        widget.on(::Crysterm::Event::Blur) { block.call "blur", nil }
      when "select", "change"
        widget.on(::Crysterm::Event::SelectItem) { |e| block.call event_name, e.index.to_s }
      end
    end

    # Declarative action interpreter: lets simple behavior live entirely in the
    # HTML, so an app can be fully driven without any handler process. An action
    # is *declarative* when it names a built-in verb (optionally with
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
      # of destroying the screen directly.
      def self.run(action : String, source : Widget, screen : Screen, on_quit : Proc(Nil)? = nil) : Bool
        verb, _, rest = action.partition(':')
        case verb
        when "quit"
          on_quit ? on_quit.call : screen.destroy
        when "focus"
          targets(rest, source, screen).each &.focus
        when "add-class", "remove-class", "toggle-class"
          sel, _, klass = rest.partition(':')
          targets(sel, source, screen).each do |w|
            case verb
            when "add-class"    then w.add_css_class klass
            when "remove-class" then w.remove_css_class klass
            when "toggle-class" then w.toggle_css_class klass
            end
          end
        when "set-content"
          sel, _, text = rest.partition(':')
          targets(sel, source, screen).each &.set_content(text)
        else
          return false
        end
        screen.render
        true
      end

      private def self.targets(selector : String, source : Widget, screen : Screen) : Array(Widget)
        case selector
        when "", "@self" then [source]
        else                  screen.resolve_selector selector
        end
      end
    end
  end

  class Screen
    # Wires declarative `on*` actions in the loaded tree so simple apps need no
    # handler process. Named (non-declarative) actions are ignored here — the
    # HTTP bridge handles those. `on_quit` lets a host unwind cleanly on `quit`.
    def wire_dom_actions(on_quit : Proc(Nil)? = nil) : Nil
      DOM.each_binding(self) do |widget, _type, action, _value|
        DOM::Actions.run(action, widget, self, on_quit) if DOM::Actions.declarative?(action)
      end
    end
  end
end
