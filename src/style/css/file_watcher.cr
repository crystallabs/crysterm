module Crysterm
  module CSS
    # File-watching is temporarily DISABLED.
    #
    # Was a cross-platform single-file watcher backed by the `fswatch` shard
    # (FSEvents/inotify/kqueue/stat-poll), used for stylesheet/layout
    # hot-reload. The `fswatch` dependency was removed from `shard.yml` pending
    # re-integration via `event_handler`.
    #
    # Original implementation watched the file's directory (non-recursive) and
    # filtered events to the target basename, catching editor
    # write-temp-then-rename saves. See git history to restore it.
    module FileWatcher
      # No-op stub. Previously watched *path*, invoked *callback* on changes,
      # and returned the running `FSWatch::Session`. Always returns `nil` now;
      # callers degrade to no hot-reload.
      def self.watch(path : String, latency : Float64 = 0.1, &_callback : ->) : Nil
        nil
      end
    end
  end
end
