module Crysterm
  module Macros
    # Defines new_method as an alias of old_method.
    #
    # This creates a new method new_method that invokes old_method.
    #
    # Note that due to current language limitations this is only useful
    # when neither named arguments nor blocks are involved.
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
        alias_method new_method, {{@type.methods.last.name}}
      {% end %}
    end

    # Registers a handler for the event, named after the event itself.
    # This is a convenience function.
    #
    # E.g.:
    # ```
    # handle Event::Attach
    # ```
    #
    # Will expand into:
    #
    # ```
    # on(Event::Attach, ->on_attach(Event::Attach)
    # ```
    macro handle(event, handler = nil)
      on({{event}}, ->on_{{ handler || (event.stringify.split("::")[-1].downcase.id) }}({{event}}))
    end
  end
end
