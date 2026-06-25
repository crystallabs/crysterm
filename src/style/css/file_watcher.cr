module Crysterm
  module CSS
    # File-watching is temporarily DISABLED.
    #
    # This was a cross-platform single-file watcher backed by the `fswatch`
    # shard (libfswatch: FSEvents/inotify/kqueue/stat-poll), used for stylesheet
    # and layout hot-reload. The `fswatch` dependency has been removed from
    # `shard.yml` pending re-integration of file-change events via
    # `event_handler`.
    #
    # The original implementation watched the file's *directory* (non-recursive)
    # and filtered events to the target basename, so editor write-temp-then-rename
    # save patterns were caught. See git history to restore it.
    module FileWatcher
      # No-op stub. Previously watched *path* and invoked *callback* on changes,
      # returning the running `FSWatch::Session`. With watching disabled this
      # does nothing and returns `nil`, so callers degrade to no hot-reload.
      def self.watch(path : String, latency : Float64 = 0.1, &_callback : ->) : Nil
        nil
      end
    end
  end
end
