require "fswatch"

module Crysterm
  module CSS
    # Cross-platform single-file watcher backed by the `fswatch` shard
    # (libfswatch: FSEvents on macOS, inotify on Linux, kqueue on the BSDs, with
    # a portable stat-poll fallback on platforms without a native backend).
    #
    # Used for stylesheet hot-reload (`Screen#watch_stylesheet`), but the API is
    # deliberately generic (path + callback) so the same mechanism can later be
    # surfaced through `event_handler` as user-facing file-change events.
    #
    # The file's *directory* is watched (non-recursively) and events are filtered
    # to the target basename, so editor save patterns that replace the file
    # (write-temp-then-rename) are caught, not just in-place writes — and so the
    # comparison is unaffected by backends (e.g. FSEvents) that report
    # symlink-resolved paths.
    module FileWatcher
      # Watches *path* for modifications, invoking *callback* on each change.
      #
      # Returns the running `FSWatch::Session`. The monitor runs on its own
      # thread; libfswatch coalesces bursts within *latency* seconds and the
      # shard marshals each batch back to a regular Crystal fiber, so *callback*
      # runs cooperatively on the main thread (safe to render from). Keep the
      # returned session referenced — a collected session stops monitoring — and
      # call `#stop_monitor` on it to end watching.
      def self.watch(path : String, latency : Float64 = 0.1, &callback : ->) : FSWatch::Session
        base = File.basename(path)
        dir = File.dirname(File.expand_path(path))

        session = FSWatch::Session.new
        session.latency = latency
        session.recursive = false
        session.on_change do |event|
          callback.call if File.basename(event.path) == base
        end
        session.add_path dir
        session.start_monitor
        session
      end
    end
  end
end
