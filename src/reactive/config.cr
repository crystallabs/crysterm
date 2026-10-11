module Crysterm
  module Reactive
    # A `Property` kept in step with the `Crysterm::Config` (Superconf) option
    # *key*, in both directions: the property starts at the option's current
    # value; assigning the property sets the option at runtime precedence
    # (`Superconf.set`), as a menu entry or a dialog does on the user's
    # behalf; and a change to the option from any source — a settings file
    # the application loads while it runs, a `reset`, an assignment through
    # the typed accessor — comes back into the property, so whatever is bound
    # to it (`Reactive.bind`, `Action#bind_checked`) follows. *type* is the
    # option's value type, as `Superconf.get` takes it.
    #
    # ```
    # theme = Crysterm::Reactive.config_property "colors.theme", Crysterm::CSS::Theme::Choice
    # theme.on_change { apply theme.value }
    # theme.value = Crysterm::CSS::Theme::Choice::Dark                      # Config.colors_theme is now Dark
    # Crysterm::Config.load_file "settings.yml", Superconf::Source::Runtime # the property follows
    # ```
    def self.config_property(key : String, type : T.class) : Property(T) forall T
      link_config Property.new(Superconf.get(key, T)), key
    end

    # Links an existing *property* to the option *key* the way
    # `.config_property` makes one: the option's current value is put into
    # the property first, then the two follow each other. For a property a
    # widget or an application already owns and has handlers on. Returns the
    # property.
    #
    # The two guards against echo are the property's own (an assignment of
    # an equal value is a no-op) and the option's (a `set` to the value it
    # holds notifies no one), so the loop property → option → property
    # stops after one step.
    def self.link_config(property : Property(T), key : String) : Property(T) forall T
      property.value = Superconf.get(key, T)
      Superconf.on_change(key) { property.value = Superconf.get(key, T) }
      property.on_change { Superconf.set key, property.value }
      property
    end
  end
end
