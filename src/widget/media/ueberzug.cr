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
    # override-redirect window stays on top, so it isn't covered by later-drawn
    # text and needs no per-frame repaint. `add` is therefore only (re)sent when
    # the cell rectangle changes, and `remove` on hide/detach/destroy.
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

      # Überzug scaler: how the image is fit into its placement rectangle.
      # `ForcedCover` fills the box exactly.
      enum Scaler
        FitContain
        Contain
        ForcedCover
        Cover
        Crop
        Distort

        # Wire string this member is serialized to in the JSON protocol sent
        # to the `ueberzug`/`ueberzugpp` helper process.
        def to_wire : String
          case self
          in .fit_contain?  then "fit_contain"
          in .contain?      then "contain"
          in .forced_cover? then "forced_cover"
          in .cover?        then "cover"
          in .crop?         then "crop"
          in .distort?      then "distort"
          end
        end
      end

      getter scaler : Scaler

      # Changing the scaler must re-send `add`: the placement is only re-sent
      # when the rect changes (`redraw_image`'s `return if rect == @last`), so
      # nil `@last` (like `#load` does) and request a render. Genuine-change
      # guarded, mirroring `Media::Base#fit=`, so per-frame reconciles don't
      # churn.
      def scaler=(v : Scaler) : Scaler
        unless v == @scaler
          @scaler = v
          @last = nil
          request_render
        end
        v
      end

      # One shared helper process drives every placement (keyed by identifier).
      @@proc : Process? = nil
      @@counter = 0

      @id : String
      @last : Tuple(Int32, Int32, Int32, Int32)? = nil
      @path : String? = nil
      # Path of the temp file a URL-sourced image was fetched into, so it can be
      # deleted on reload/clear/teardown instead of leaking into `/tmp`.
      @tmp_path : String? = nil

      # `fit`/`animate`/`speed` are accepted so the `Media` factory can forward
      # them uniformly, but are advisory here: überzug does its own scaling
      # (`scaler`) and can't animate.
      def initialize(@file = nil, @scaler : Scaler = Scaler::ForcedCover,
                     @fit : Media::Fit = Media::Fit::Stretch,
                     @animate : Bool = false,
                     speed : Float64 = 1.0, **box)
        super **box
        @@counter += 1
        @id = "crysterm_#{@@counter}"
        # Route through the validating setter so speed: 0/NaN/Infinity is clamped
        # to 1.0. Must follow the @id assignment: calling a method on `self` before
        # every non-nilable ivar is set would make @id nilable.
        self.speed = speed

        @file.try { |f| load f }

        register_render_hook_deferred { redraw_image }

        on(::Crysterm::Event::Hide) { remove }
        on(::Crysterm::Event::Detached) { remove }
        on(::Crysterm::Event::Show) { @last = nil; request_render }
        on(::Crysterm::Event::Destroy) { teardown }
      end

      def load(file : String)
        @file = file
        @path = local_path file
        if @path
          # Usable path: force a re-add of the new image on the next redraw.
          @last = nil
        else
          # Unusable path (failed URL fetch, tempfile, or write): there is nothing
          # to show, so take the stale placement down instead of orphaning it.
          # `remove` clears @last itself.
          remove
        end
        # Explicit request: the überzug placement is (re)added by the post-render
        # hook, not by the normal dirty/render path, so nothing else schedules
        # the frame that fires it.
        request_render
      end

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
          # Reap before replacing, or the dead helper lingers as a zombie — and
          # `terminated?` (a `kill(pid, 0)` probe) would then report that zombie
          # as still alive and hand it back as "live".
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
          scaler:     @scaler.to_wire,
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
        # Helper went away (EPIPE on write). Reap the dead process, drop the
        # cache so the next call respawns, and retry once on the fresh helper so
        # the placement isn't silently lost until the rect next changes.
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

      # Fetches *file*'s bytes over the network. Kept as a seam so tests can
      # exercise the temp-file lifecycle without network access.
      protected def fetch_bytes(file : String) : Bytes
        Widget::Media::Ansi.fetch file
      end

      # Path of the temp file the most recent URL fetch wrote to, if any.
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
