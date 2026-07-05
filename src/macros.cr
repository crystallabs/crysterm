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
    #
    # This macro was present in Crystal until commit 7c3239ee505e07544ec372839efed527801d210a.
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
    # *before* the emit so in-tree listeners observe the new value, not the old
    # one (`Move` listeners for a position change, `Resize` for a size/constraint
    # change). Homes the byte-identical bodies of `left=`/`top=`/`right=`/
    # `bottom=` (Move) and `width=`/`height=`/`min_*=`/`max_*=` (Resize).
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

    # Defines a per-Window pooled mouse-event factory: a nilable `@_<name>_event`
    # ivar plus a private `<name>_event(ev)` that lazily constructs one instance
    # of `Crysterm::Event::<klass>` and `reset`s it on every dispatch, so a
    # high-frequency mouse report doesn't heap-allocate a fresh event each time.
    # See `Event::Mouse#reset` for the retention caveat.
    macro pooled_mouse_event(name, klass)
      @_{{name.id}}_event : Crysterm::Event::{{klass.id}}?

      private def {{name.id}}_event(ev : ::Tput::Mouse::Event) : Crysterm::Event::{{klass.id}}
        (@_{{name.id}}_event ||= Crysterm::Event::{{klass.id}}.new(ev)).reset ev
      end
    end

    # Registers a handler for the event, named after the event itself.
    #
    # E.g.:
    # ```
    # handle Event::Attach
    # ```
    #
    # Expands into:
    #
    # ```
    # on(Event::Attach, ->on_attach(Event::Attach)
    # ```
    macro handle(event, handler = nil)
      on({{event}}, ->on_{{ handler || (event.stringify.split("::")[-1].downcase.id) }}({{event}}))
    end
  end
end
