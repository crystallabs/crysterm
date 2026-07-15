module Crysterm
  module CSS
    # Single-file watcher for stylesheet/layout hot-reload. Currently disabled.
    module FileWatcher
      # No-op stub: watching is disabled, so callers degrade to no hot-reload.
      def self.watch(path : String, latency : Float64 = 0.1, &_callback : ->) : Nil
        nil
      end
    end
  end
end
