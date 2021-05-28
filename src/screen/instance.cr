module Crysterm
  module Widget
    class Screen
      module Instance

        macro included
          class_getter instances = [] of self

          @@global : Crysterm::Widget::Screen?

          def self.total
            @@instances.size
          end

          def self.global(create : Bool = true)
            (instances[0]? || (create ? new : nil)).not_nil!
          end

          @@_bound = false
        end

        def bind
          @@global = self unless @@global

          @@instances << self # unless @@instances.includes? self

          return if @@_bound
          @@_bound = true

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
          leave

          @render_flag.set 2

          if @@instances.delete self
            if @@instances.any?
              @@global = @@instances[0]
            else
              #@@global = nil # XXX
              # TODO remove all signal handlers set up on the app's process
              @@_bound = false
            end

            @destroyed = true
            emit Crysterm::Event::Destroy

            #super # No longer exists since we're not subclass of Node any more
          end

          app.destroy
        end

      end
    end
  end
end
