module Crysterm
  module Widget
    class Screen < Node
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

            @destroyed = true # XXX
            emit Crysterm::Event::Destroy

            super
          end

          app.destroy
        end

      end
    end
  end
end

# Observed behavior (2 issues in function destroy()):
# Function destroy() is not called by the time the issues happen, but still:
#
# 1. If line 54 is uncommented, then compilation fails with:
# Error: class variable '@@global' of Crysterm::Widget::Screen is already defined as Nil in Crysterm::Widget::Screen::Instance
#
# 2. If line 59 is uncommented (which it is now, to trigger the bug), then either the compilation or beginning of runtime fail with:
# Invalid memory access (signal 11) at address 0x0
# [0x7f21954f0bf6] ???
# [0x7f219543fab2] ???
# [0x7f2196487e0f] ???
#
#
# How to reproduce (I used Crystal 1.0.0):
# git clone https://github.com/crystallabs/crysterm
# cd crysterm
# shards --ignore-crystal-version
# crystal  examples/tech-demo.cr 
#
# (If tech-demo.cr runs without crashing, you can exit it by killing the process,
# just run `pkill crystal` (assuming nothing else with `crystal` is currently running
# on your system))
