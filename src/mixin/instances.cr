module Crysterm
  module Mixin
    module Instances
      macro included
        # List of existing instances.
        #
        # For automatic management, `#bind` must be called at creation and
        # `#destroy` at termination. `#bind` doesn't need to be called
        # explicitly (it happens during `#initialize`); `#destroy` does.
        class_getter instances = [] of self

        # Returns number of created instances
        def self.total
          @@instances.size
        end

        # Creates and/or returns the "global" instance — the most recently
        # created one (`instances[-1]`). If none exist yet and *create* is
        # true, a new one is created.
        #
        # Alternative (not implemented): hold the global in a class variable so
        # the default object is configurable at runtime.
        def self.global(create : Bool = true)
          (instances[-1]? || (create ? new : nil)).not_nil!
        end
      end

      # Accounts for itself in `@@instances` and does other related work.
      def bind
        if @@instances.includes? self
          return
        end

        @@instances << self

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

      # Destroys self and removes it from the global list of `Window`s, and
      # removes all global events relevant to the object.
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
