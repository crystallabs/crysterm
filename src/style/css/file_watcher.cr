module Crysterm
  module CSS
    # Single-file watcher for stylesheet/layout hot-reload.
    #
    # Zero-dependency mtime poller: a fiber checks the file every *latency*
    # seconds and invokes the callback when the modification time changes. A
    # vanished file is tolerated (the watch keeps polling and fires again when
    # the file reappears with a new mtime), so editor save strategies that
    # replace the file are handled.
    module FileWatcher
      # Handle for one active watch. `#stop` ends the polling fiber (at its
      # next wakeup); stopping an already-stopped watch is a no-op.
      class Watch
        @stopped = false

        def stop : Nil
          @stopped = true
        end

        def stopped? : Bool
          @stopped
        end
      end

      # Starts watching *path*, invoking *callback* (in the watcher's fiber)
      # whenever the file's mtime changes. Returns the `Watch` handle used to
      # stop it. Callback errors are swallowed: a hot-reload hiccup (partial
      # save, transient parse error handled upstream) must not kill the watch.
      def self.watch(path : String, latency : Float64 = 0.5, &callback : ->) : Watch
        watch = Watch.new
        spawn(name: "css-file-watcher #{path}") do
          last = File.info?(path).try &.modification_time
          until watch.stopped?
            sleep latency.seconds
            next if watch.stopped?
            mtime = File.info?(path).try &.modification_time
            if mtime && mtime != last
              last = mtime
              begin
                callback.call
              rescue
              end
            end
          end
        end
        watch
      end
    end
  end
end
