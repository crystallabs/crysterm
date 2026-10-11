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
    # option's value type, as `Superconf.get` takes it. The link lasts as
    # long as *owner* — a `Window`, a `Widget`, any `EventHandler` whose
    # `Event::Destroy` ends it — or, without one, as long as the process;
    # `.link_config` returns the `ConfigLink` that also ends it by hand.
    #
    # ```
    # theme = Crysterm::Reactive.config_property "colors.theme", Crysterm::CSS::Theme::Choice, window
    # theme.on_change { apply theme.value }
    # theme.value = Crysterm::CSS::Theme::Choice::Dark                      # Config.colors_theme is now Dark
    # Crysterm::Config.load_file "settings.yml", Superconf::Source::Runtime # the property follows
    # ```
    def self.config_property(key : String, type : T.class, owner : ::EventHandler? = nil) : Property(T) forall T
      property = Property.new(Config.get(key, T))
      link_config property, key, owner
      property
    end

    # Links an existing *property* to the option *key* the way
    # `.config_property` makes one: the option's current value is put into
    # the property first, then the two follow each other. For a property a
    # widget or an application already owns and has handlers on. Returns
    # the `ConfigLink`, which `#dispose` ends; *owner*'s `Event::Destroy`
    # ends it too, so a destroyed window's properties stop hearing the
    # options.
    #
    # The two guards against echo are the property's own (an assignment of
    # an equal value is a no-op) and the option's (a `set` to the value it
    # holds notifies no one), so the loop property → option → property
    # stops after one step.
    def self.link_config(property : Property(T), key : String, owner : ::EventHandler? = nil) : ConfigLink forall T
      property.value = Config.get(key, T)
      link = ConfigLink.new key, Config.on_change(key) { property.value = Config.get(key, T) }
      link.watch property
      link.attach_auto_dispose owner if owner
      link
    end

    # The two-way link `Reactive.link_config` makes between a `Property` and
    # a config option: disposing it unhooks both sides.
    class ConfigLink
      @subs = ::Crysterm::Subscriptions.new
      getter? disposed = false

      # *handle* is the option-side listener, as `Superconf.on_change`
      # returned it.
      def initialize(@key : String, @handle : Proc(Nil))
      end

      # Hooks the property side: an assignment sets the option at runtime
      # precedence.
      protected def watch(property : Property(T)) : Nil forall T
        key = @key
        @subs.on(property, ::Crysterm::Event::ReactiveChanged) { Config.set key, property.value }
      end

      # Ends the link at *owner*'s `Event::Destroy`.
      protected def attach_auto_dispose(owner : ::EventHandler) : Nil
        @subs.auto_dispose(owner) { dispose }
      end

      # Unhooks the option's listener and the property's, so neither side
      # hears the other again. Idempotent.
      def dispose : Nil
        return if @disposed
        @disposed = true
        Config.off_change @key, @handle
        @subs.off
      end
    end
  end
end
