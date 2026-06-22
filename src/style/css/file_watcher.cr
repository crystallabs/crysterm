module Crysterm
  module CSS
    # Minimal event-based (inotify) watcher for a single file — Linux only.
    #
    # Used for opt-in stylesheet hot-reload (`Screen#watch_stylesheet`); there is
    # no polling and nothing runs unless explicitly started. The file's
    # *directory* is watched (filtered to the basename) so editor save patterns
    # that replace the file (write-temp-then-rename) are caught, not just
    # in-place writes.
    module FileWatcher
      @[Link("c")]
      lib LibInotify
        fun inotify_init1(flags : LibC::Int) : LibC::Int
        fun inotify_add_watch(fd : LibC::Int, pathname : LibC::Char*, mask : LibC::UInt) : LibC::Int
      end

      IN_NONBLOCK    = 0x800_u32 # O_NONBLOCK
      IN_CLOSE_WRITE =   0x8_u32
      IN_MOVED_TO    =  0x80_u32

      # Watches *path* for modifications, invoking *callback* on each change.
      # Returns the spawned `Fiber`. Raises if inotify can't be set up.
      def self.watch(path : String, &callback : ->) : Fiber
        dir = File.dirname(path)
        base = File.basename(path)

        fd = LibInotify.inotify_init1(IN_NONBLOCK.to_i)
        raise "inotify_init1 failed" if fd < 0
        wd = LibInotify.inotify_add_watch(fd, dir, IN_CLOSE_WRITE | IN_MOVED_TO)
        raise "inotify_add_watch failed for #{dir.inspect}" if wd < 0

        io = IO::FileDescriptor.new(fd)
        spawn do
          buffer = Bytes.new(4096)
          loop do
            read = io.read(buffer) # suspends the fiber until events arrive
            break if read <= 0
            each_event(buffer[0, read]) { |name| callback.call if name == base }
          end
        rescue
          # fd closed / error: stop watching silently
        end
      end

      # Iterates the `struct inotify_event` records packed into *bytes*
      # (`{ int wd; uint32 mask, cookie, len; char name[len]; }`), yielding each
      # event's filename.
      private def self.each_event(bytes : Bytes, &)
        offset = 0
        while offset + 16 <= bytes.size
          len = IO::ByteFormat::LittleEndian.decode(UInt32, bytes[offset + 12, 4]).to_i
          name_start = offset + 16
          break if name_start + len > bytes.size
          name = len > 0 ? String.new(bytes[name_start, len].to_unsafe) : ""
          yield name
          offset = name_start + len
        end
      end
    end
  end
end
