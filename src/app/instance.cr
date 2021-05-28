module Crysterm
  class App
    # Functionality related to instances of an `App`.
    #
    # In general, this functionality exists so that multiple, separate `App`s
    # could exist within a single process.
    module Instance
      macro included
        class_getter instances = [] of self

        # Returns number of `App` instances
        def self.total
          @@instances.size
        end

        # Creates and/or returns the "global" (by default the first) instance of `App`
        def self.global(create = true)
          ( instances[0]? || (create ? new : nil)).not_nil!
        end

        @@_bound = false
      end

      # Registers an `App`. Happens automatically during `initialize`; generally not used directly.
      def bind
        @@global = self unless @@global

        @@instances << self # unless @@instances.includes? self

        return if @@_bound
        @@_bound = true

        at_exit do
          # XXX Should these completely separate loops somehow
          # be rearranged and/or combined more nicely? Is defining this
          # per each App instance that calls bind even OK?

          self.class.instances.each do |app|
            # XXX Do we restore window title ourselves?
            # if app._original_title
            #  app.tput.set_title(...)
            # end

            app.tput.try do |tput|
              tput.flush
              tput._exiting = true
            end
          end

          Crysterm::Widget::Screen.instances.each do |screen|
            screen.destroy
          end
        end
      end

      # Runs the app, similar to how it is done in the Qt framework.
      def exec(screen : Crysterm::Widget::Screen? = nil)
        (screen || Crysterm::Widget::Screen.global(true)).render
        sleep
      end

      # Destroys an `App` instance
      def destroy
        if @@instances.delete self
          tput.try do |tput|
            tput.flush
            tput._exiting = true
          end

          if @@instances.any?
            @@global = @@instances[0]
          else
            @@global = nil
            # TODO remove all signal handlers set up on the app's process
            # Primarily, exit handler
            @@_bound = false
          end

          # TODO rest of stuff; e.g. reset terminal back to usable

          @destroyed = true
          emit Crysterm::Event::Destroy

          if Widget::Screen.instances.empty?
            @input.cooked! # XXX This is maybe to basic of a "return to previous state" method.
            exit
          end
        end
      end

      # Returns true if the app objects are being destroyed; otherwise returns false.
      property? exiting : Bool = false
      # XXX Is this an alias with `closing_down?`

      # XXX Is there a difference between `exiting` and `_exiting`, or those are the same? Adjust if needed.
      property? _exiting = false

      # End of stuff related to multiple instances

      # XXX Save/restore all state here. What else? Stop main loop etc.?
      def quit
        @exiting = true
      end
    end
  end
end
