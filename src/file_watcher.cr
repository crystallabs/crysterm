module Crysterm
  # Watches files for changes by polling — the `QFileSystemWatcher` analogue.
  # Every *interval* it stats each watched path (`File.info?`) and emits
  # `Event::FileChanged` for those whose size or modification time differs
  # from the last look, or which appeared or disappeared since. Handlers get
  # the path as it was added.
  #
  # Polling, not kernel notification (no `inotify`/`kqueue` binding), so a
  # change shows up at most one *interval* late, and a write that leaves the
  # file at the same size with the same modification time (within the file
  # system's timestamp resolution) is not detectable. The usual case — a
  # document saved by another program while a viewer shows it — is caught.
  #
  # Given a *window*, the events are delivered on its render fiber (through
  # `Window#post`), so a handler may touch widgets directly; without one they
  # run on the watcher's timer fiber and must not.
  #
  # ```
  # watcher = Crysterm::FileWatcher.new window: window
  # watcher.add_path path
  # watcher.on(Crysterm::Event::FileChanged) do |e|
  #   viewer.set_markdown File.read(e.path)
  # end
  # ```
  #
  # The watcher runs from construction until `#stop`; `#start` resumes it.
  class FileWatcher
    include EventHandler

    # What was last seen of a watched file: its size and modification time,
    # or `nil` while it does not exist. A tuple, not the `File::Info` itself,
    # so two looks compare by value.
    alias Stamp = {Int64, Time}?

    # How often the paths are checked.
    getter interval : Time::Span

    # Window whose render fiber the events are delivered on, if any.
    getter window : Window?

    @stamps = {} of String => Stamp
    @timer : Timer?

    # Creates a watcher checking its paths every *interval*, already running
    # (it ticks idly until the first `#add_path`). With *window*, events are
    # delivered on that window's render fiber; see the class docs.
    def initialize(@interval : Time::Span = 1.second, *, @window : Window? = nil)
      start
    end

    # Starts watching the files; emits `Event::FileChanged` on this watcher's
    # fiber (or posts it to the window) when a watched file changed. Idempotent
    # while running; after `#stop`, resumes.
    def start : Nil
      return if @timer
      @timer = Timer.every(@interval) { poll }
    end

    # Stops checking the paths. They stay registered along with what was last
    # seen of them, so a change made while stopped is reported on the first
    # look after `#start`.
    def stop : Nil
      @timer.try &.stop
      @timer = nil
    end

    # Whether the watcher is currently polling.
    def running? : Bool
      !@timer.nil?
    end

    # Starts watching *path* (which need not exist yet: its appearance is a
    # change). Adding a path already watched does nothing.
    def add_path(path : String) : Nil
      return if @stamps.has_key? path
      @stamps[path] = stamp path
    end

    # Stops watching *path*. Unknown paths are ignored.
    def remove_path(path : String) : Nil
      @stamps.delete path
    end

    # The watched paths, in the order they were added.
    def paths : Array(String)
      @stamps.keys
    end

    # One look at every path: emits for those that changed, and remembers
    # what was seen so the next look compares against it.
    private def poll : Nil
      # Iterate a snapshot: a handler may `remove_path` under the iteration.
      @stamps.dup.each do |path, seen|
        now = stamp path
        next if now == seen
        @stamps[path] = now
        notify path
      end
    end

    private def stamp(path : String) : Stamp
      if info = File.info?(path)
        {info.size, info.modification_time}
      end
    end

    private def notify(path : String) : Nil
      if w = @window
        w.post { emit Crysterm::Event::FileChanged, path }
      else
        emit Crysterm::Event::FileChanged, path
      end
    end
  end
end
