module Crysterm
  module Mixin
    module Instances
      macro included
        # List of existing instances.
        #
        # For automatic management, `#register_instance` must be called at
        # creation and `#destroy` at termination. `#register_instance` doesn't
        # need to be called explicitly (it happens during `#initialize`);
        # `#destroy` does.
        class_getter instances = [] of self

        # Creates and/or returns the "global" instance — the most recently
        # created one. If none exist yet, a new one is created, so the result is
        # never nil.
        def self.global : self
          instances[-1]? || new
        end

        # Returns the "global" instance (most recently created), or `nil` when
        # none exist yet. A pure query — unlike `#global`, it never creates one.
        def self.global? : self?
          instances[-1]?
        end
      end

      # Accounts for itself in `@@instances` and does other related work.
      protected def register_instance
        if @@instances.includes? self
          return
        end

        @@instances << self
      end

      # Destroys self and removes it from the global list of `Window`s, and
      # removes all global events relevant to the object.
      def destroy
        if @@instances.delete self
          emit Crysterm::Event::Destroy
        end
      end
    end
  end
end
