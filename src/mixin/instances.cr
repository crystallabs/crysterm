module Crysterm
  module Mixin
    module Instances
      macro included
        # List of existing instances.
        #
        # For automatic management of this list, make sure that `#bind` is called at
        # creation and `#destroy` at termination.
        #
        # `#bind` does not have to be called explicitly because it happens during `#initialize`.
        # `#destroy` does need to be called.
        class_getter instances = [] of self

        # Returns number of created instances
        def self.total
          @@instances.size
        end

        # Creates and/or returns the "global" (first) created instance.
        #
        # An alternative approach, which is currently not implemented, would be to hold the global
        # in a class variable, and return it here. In that way, the choice of the default/global
        # object at a particular time would be configurable in runtime.
        def self.global(create : Bool = true)
          (instances[-1]? || (create ? new : nil)).not_nil!
        end
      end

      # Accounts for itself in `@@instances` and does other related work.
      def bind
        @@instances << self # unless @@instances.includes? self

        # return if @@_bound
        # @@_bound = true

        # TODO Enable
        # ['SIGTERM', 'SIGINT', 'SIGQUIT'].each do |signal|
        #  name = '_' + signal.toLowerCase() + 'Handler'
        #  Signal::<>.trap do
        #    if listeners(signal).size > 1
        #      return;
        #    end
        #    process.exit(0);
        #  end
        # end
      end

      # Destroys self and removes it from the global list of `Screen`s.
      # Also remove all global events relevant to the object.
      # If no screens remain, the app is essentially reset to its initial state.
      def destroy
        if @@instances.delete self
          # if @@instances.empty?
          #  @@_bound = false
          # end

          emit Crysterm::Event::Destroy

          # super # No longer exists since we're not subclass of Node any more
        end

        # display.destroy
      end
    end
  end
end
