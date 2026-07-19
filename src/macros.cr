module Crysterm
  module Macros
    # Defines new_method as an alias of old_method.
    #
    # Creates a new method new_method that invokes old_method. Due to current
    # language limitations this only works when neither named arguments nor
    # blocks are involved.
    #
    # ```
    # class Person
    #   getter name
    #
    #   def initialize(@name)
    #   end
    #
    #   alias_method full_name, name
    # end
    #
    # person = Person.new "John"
    # person.name      # => "John"
    # person.full_name # => "John"
    # ```
    macro alias_method(new_method, old_method)
      def {{new_method.id}}(*args)
        {{old_method.id}}(*args)
      end
    end

    # Defines new_method as an alias of last (most recently defined) method.
    macro alias_previous(*new_methods)
      {% for new_method in new_methods %}
        alias_method {{new_method}}, {{@type.methods.last.name}}
      {% end %}
    end

    # Defines a change-guarded property setter: bail if unchanged, otherwise
    # assign, mark the widget dirty, then emit *event*. The assign happens
    # *before* the emit so listeners observe the new value, not the old one.
    #
    # The backing ivar is `@name`. Pass *val_type* to type-annotate the argument.
    macro change_guarded_setter(name, event, val_type = nil)
      def {{name.id}}=(val{% if val_type %} : {{val_type.id}}{% end %})
        return if @{{name.id}} == val
        @{{name.id}} = val
        mark_dirty
        emit ::Crysterm::Event::{{event.id}}
      end
    end

    # Declares a signal-backed widget property — the reactive sibling of
    # `change_guarded_setter`. Given `reactive_property title : String = ""` it
    # generates:
    #
    # * `#title_signal` — the backing `Reactive::Signal(String)`, created lazily
    #   on first use with the declared default (no allocation until touched).
    #   Bind against it (`Reactive.bind(dst, obj.title_signal) { … }`).
    # * `#title` — reads the value; **tracks** the property as a dependency when
    #   read inside an `Effect`/`Computed`, so `obj.title` participates in
    #   auto-tracking just like a bare signal read.
    # * `#title=` — change-guarded assign. On a real change it notifies signal
    #   subscribers, `mark_dirty`s, and schedules a repaint of the owning window,
    #   so a bare `obj.title = "x"` both fans out to bindings/effects and redraws
    #   the widget itself. Pass *event* to also emit a widget-level event (parity
    #   with `change_guarded_setter`).
    #
    # A default value is required (the signal needs an initial value). Assumes the
    # including type is a `Widget` (uses `mark_dirty`/`window?`), like
    # `change_guarded_setter`.
    #
    # Like `enum_property`, the `name : Type = default` argument reads as an
    # assignment to `ameba`, so prefix each call site with
    # `# ameba:disable Lint/UselessAssign`.
    macro reactive_property(decl, event = nil)
      {% raise "reactive_property #{decl.var} requires a default value" unless decl.value %}

      @{{decl.var}} : ::Crysterm::Reactive::Signal({{decl.type}})?

      def {{decl.var}}_signal : ::Crysterm::Reactive::Signal({{decl.type}})
        @{{decl.var}} ||= ::Crysterm::Reactive::Signal({{decl.type}}).new({{decl.value}})
      end

      def {{decl.var}} : {{decl.type}}
        {{decl.var}}_signal.value
      end

      def {{decl.var}}=(val : {{decl.type}}) : {{decl.type}}
        sig = {{decl.var}}_signal
        # Untracked guard read (`#peek`, not `#value`) so a setter called from
        # inside an effect doesn't spuriously depend on the property.
        return val if sig.peek == val
        sig.value = val
        mark_dirty
        window?.try &.schedule_render
        {% if event %} emit ::Crysterm::Event::{{event.id}} {% end %}
        val
      end
    end

    # Defines a per-Window pooled mouse-event factory: a nilable `@_<name>_event`
    # ivar plus a private `<name>_event(ev)` that lazily constructs one instance
    # of `Crysterm::Event::<klass>` and `reset`s it on every dispatch, so a
    # high-frequency mouse report doesn't heap-allocate a fresh event each time.
    macro pooled_mouse_event(name, klass)
      @_{{name.id}}_event : Crysterm::Event::{{klass.id}}?

      private def {{name.id}}_event(ev : ::Tput::Mouse::Event, target : Widget? = nil) : Crysterm::Event::{{klass.id}}
        (@_{{name.id}}_event ||= Crysterm::Event::{{klass.id}}.new(ev)).reset ev, target
      end
    end

    # Registers a handler for the event, named after the event itself.
    #
    # E.g.:
    # ```
    # handle Event::Attached
    # ```
    #
    # Expands into:
    #
    # ```
    # on(Event::Attached, ->on_attached(Event::Attached)
    # ```
    macro handle(event, handler = nil)
      on({{event}}, ->on_{{ handler || (event.stringify.split("::")[-1].downcase.id) }}({{event}}))
    end
  end
end
