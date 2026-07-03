require "../../widget_media_base"
require "json"

module Crysterm
  class Widget
    # Renders a true-color image via **Überzug / Überzug++** (`ueberzug`), the
    # modern successor to `w3mimgdisplay`. Like `Media::Overlay` this is an
    # *out-of-band* overlay: an external helper draws the actual image pixels in
    # its own X11 child window placed over the terminal — pixels owned by
    # neither Crysterm's cell grid nor the terminal emulator.
    #
    # Differs from `Media::Overlay` in two ways: the helper speaks a JSON
    # protocol on stdin (`{"action":"add",…}` / `{"action":"remove",…}`) and
    # positions/sizes placements in *terminal cells* (not pixels); and its
    # override-redirect window stays on top, so — unlike w3m — it doesn't get
    # covered by subsequently drawn text and need re-painting every frame. So we
    # just (re)send `add` when the cell rectangle changes and `remove` on
    # hide/detach/destroy.
    #
    # Requires the `ueberzug` or `ueberzugpp` binary on PATH and a real X
    # display; with neither present the widget is inert (it draws nothing).
    #
    # ```
    # img = Widget::Media::Ueberzug.new file: "pic.png", width: 40, height: 12, parent: window
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Ueberzug screenshot](../../../tests/widget/media/ueberzug/ueberzug.5s.apng)
    # <!-- /widget-examples:capture -->
    class Media::Ueberzug < Media::External
      include Media::RenderHook

      # Überzug scaler: `fit_contain`, `contain`, `forced_cover`, `cover`,
      # `crop`, `distort`. `forced_cover` fills the box exactly.
      property scaler : String

      # One shared helper process drives every placement (keyed by identifier).
      @@proc : Process? = nil
      @@counter = 0

      @id : String
      @last : Tuple(Int32, Int32, Int32, Int32)? = nil
      @path : String? = nil
      # Path of the temp file a URL-sourced image was fetched into, so it can be
      # deleted on reload/clear/teardown instead of leaking into `/tmp`.
      @tmp_path : String? = nil

      # The shared `Media::Base` contract knobs (`fit`/`animate`/`speed`) are
      # accepted so the `Media` factory can forward them uniformly, but are
      # advisory here: überzug does its own scaling (`scaler`) and can't animate.
      def initialize(@file = nil, @scaler : String = "forced_cover",
                     @fit : Media::Fit = Media::Fit::Stretch,
                     @animate : Bool = false,
                     @speed : Float64 = 1.0, **box)
        super **box
        @@counter += 1
        @id = "crysterm_#{@@counter}"

        @file.try { |f| load f }

        register_render_hook_deferred { redraw_image }

        on(::Crysterm::Event::Hide) { remove }
        on(::Crysterm::Event::Detach) { remove }
        on(::Crysterm::Event::Show) { @last = nil; request_render }
        on(::Crysterm::Event::Destroy) { teardown }
      end

      def load(file : String)
        @file = file
        @path = local_path file
        @last = nil
      end

      # `#set_image` (load + re-render) comes from `Media::External`.

      def clear_image
        remove
        @path = nil
        cleanup_tmp
        super # stop + clear file/source/frames
      end

      # Locates the helper binary once, or `nil` if neither variant is installed.
      def self.binary : String?
        return @@binary if @@checked
        @@checked = true
        {"ueberzug", "ueberzugpp", "ueberzug++"}.each do |name|
          if path = Process.find_executable(name)
            return @@binary = path
          end
        end
        @@binary = nil
      end

      @@checked = false
      @@binary : String? = nil

      # Lazily starts the shared helper process (`<binary> layer --parser json`).
      protected def self.proc : Process?
        if p = @@proc
          return p unless p.terminated?
          # Terminated: reap it before replacing. `terminated?` is `kill(pid, 0)`
          # based, which reports a *zombie* (dead but unwaited) as still alive —
          # so without this the dead helper would be handed back as "live" once,
          # and the unreaped process would linger as a zombie.
          spawn { p.wait rescue nil }
          @@proc = nil
        end
        bin = binary || return nil
        @@proc = Process.new(bin, ["layer", "--parser", "json", "--silent"],
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Close,
          error: Process::Redirect::Close)
      rescue
        nil
      end

      # (Re)places the image when its cell rectangle changes.
      private def redraw_image
        path = @path || return
        rect = overlay_geometry || return
        return if rect[2] <= 0 || rect[3] <= 0
        return if rect == @last

        send({
          action:     "add",
          identifier: @id,
          x:          rect[0],
          y:          rect[1],
          width:      rect[2],
          height:     rect[3],
          scaler:     @scaler,
          path:       path,
        })
        @last = rect
      end

      private def remove
        return if @last.nil?
        send({action: "remove", identifier: @id})
        @last = nil
      end

      private def send(command, retry_once = true)
        p = Ueberzug.proc || return
        if stdin = p.input?
          stdin.puts command.to_json
          stdin.flush
        end
      rescue
        # Helper went away (EPIPE on write). Reap the dead process (else it stays
        # a zombie — see `self.proc`) and drop the cache so the next call
        # respawns. Retry the command once on the fresh helper so the placement
        # isn't silently lost until the rect next changes.
        old = @@proc
        @@proc = nil
        old.try { |o| spawn { o.wait rescue nil } }
        send(command, retry_once: false) if retry_once
      end

      # Resolves *file* to an absolute local path the helper can open, fetching a
      # URL to a temp file if necessary.
      private def local_path(file : String) : String?
        cleanup_tmp # a previous URL fetch's temp file is now superseded
        if file =~ /^https?:/
          bytes = fetch_bytes file
          tmp = File.tempfile("crysterm_uz", File.extname(file))
          tmp.close # File.tempfile returns an open handle; close it before writing
          File.write(tmp.path, bytes)
          @tmp_path = tmp.path
        else
          File.expand_path file
        end
      rescue
        nil
      end

      # Fetches *file*'s bytes over the network. Isolated as a seam so tests can
      # exercise the temp-file lifecycle without real network access.
      protected def fetch_bytes(file : String) : Bytes
        Widget::Media::Ansi.fetch file
      end

      # Path of the temp file the most recent URL fetch wrote to (if any), so
      # tests can assert it is created and later cleaned up.
      protected def tmp_path : String?
        @tmp_path
      end

      # Deletes and forgets the fetched temp file, if one is tracked.
      protected def cleanup_tmp : Nil
        if p = @tmp_path
          File.delete? p
          @tmp_path = nil
        end
      end

      private def teardown
        remove
        cleanup_tmp
        teardown_render_hook
      end
    end
  end
end
