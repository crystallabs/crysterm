require "./abstract_item_view"
require "../mixin/item_view"

module Crysterm
  class Widget
    # File manager element.
    #
    # An `AbstractItemView` whose items are the entries of a directory. Selecting
    # a directory (with `Enter`) navigates into it; selecting a file emits
    # `Event::FileSelected`. Directory changes emit `Event::DirectoryChanged`, and each
    # (re)listing emits `Event::Refresh`.
    #
    # ```
    # fm = Widget::FileManager.new parent: window, cwd: Dir.current
    # fm.refresh
    # fm.on(Crysterm::Event::FileSelected) { |e| puts e.path }
    # fm.focus
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![FileManager screenshot](../../tests/widget/filemanager/filemanager.5s.apng)
    # <!-- /widget-examples:capture -->
    class FileManager < AbstractItemView
      include Mixin::ItemView

      # Current working directory.
      getter cwd : String

      # The directory the file manager was created in. `#reset` returns here, not
      # to wherever the user last navigated or selected.
      @initial_cwd : String

      # The most recently selected entry (directory or file), as an absolute
      # path (Qt-ish selected path).
      getter path : String

      # Whether the widget shows its current directory as its label (Qt-ish),
      # kept in sync on every navigation. Enabled by passing `label:` at
      # construction.
      @path_label : Bool

      # Real entry names (`".."`, `"foo"`, …), parallel to the rendered rows.
      # Paths must resolve from these, not the decorated row text: that carries
      # color tags and a `/`/`@` suffix, which would mangle a filename containing
      # `{...}` or a trailing `@`.
      @entry_names = [] of String

      # The FileSelected/Cancelled handlers live only for the duration of one `#pick`,
      # torn down together by `resume`.
      @pick_subs = Crysterm::Subscriptions.new

      def initialize(cwd : String? = nil, label : String? = nil, **list)
        @cwd = cwd || Dir.current
        @initial_cwd = @cwd
        @path = @cwd
        # Passing any `label:` opts the widget into the auto-updating path label.
        @path_label = !label.nil?

        super **list.merge({parse_tags: true})

        set_label @cwd if @path_label
      end

      # Reloads the listing for `cwd` (defaulting to the current directory).
      # Returns `self`.
      def refresh(cwd : String? = nil)
        prev_cwd = @cwd
        if cwd
          @cwd = cwd
        else
          cwd = @cwd
        end

        entries = begin
          Dir.children(cwd)
        rescue File::NotFoundError
          home = home_dir
          # Restore `@cwd` and re-enter through the *parameter* so the retry
          # captures the original directory as its `prev_cwd`, and announces the
          # fallback relative to where we really came from.
          @cwd = prev_cwd
          return refresh(cwd != home ? home : "/")
        rescue
          # Unreadable dir: roll `@cwd` back so it, the path label, and the
          # shown rows all stay on the last good directory rather than pointing at
          # a dir whose listing we never loaded.
          @cwd = prev_cwd
          return self
        end

        entries.unshift ".."

        dirs = [] of {name: String, text: String}
        files = [] of {name: String, text: String}

        entries.each do |name|
          f = File.expand_path(name, cwd)

          info = begin
            File.info(f, follow_symlinks: false)
          rescue
            nil
          end

          if name == ".." || (info && info.directory?)
            dirs << {name: name, text: "{light-blue-fg}#{name}{/light-blue-fg}/"}
          elsif info && info.symlink?
            files << {name: name, text: "{light-cyan-fg}#{name}{/light-cyan-fg}@"}
          else
            files << {name: name, text: name}
          end
        end

        dirs.sort_by! &.[:name]
        files.sort_by! &.[:name]

        ordered = dirs + files
        @entry_names = ordered.map &.[:name]
        self.items = ordered.map(&.[:text])
        select_index 0
        request_render

        emit Crysterm::Event::Refresh

        # Announce a directory change (label + `DirectoryChanged`) on *every* path
        # that lands somewhere new, so no caller can leave a stale path label.
        if @cwd != prev_cwd
          set_label @cwd if @path_label
          emit Crysterm::Event::DirectoryChanged, @cwd, prev_cwd
        end

        self
      end

      # Resets the file manager back to its initial directory (or *cwd*, when
      # given) and reloads. Uses the construction-time directory, not `#path`,
      # which is the last-selected entry and can be a regular file.
      def reset(cwd : String? = nil)
        # Route the target through `#refresh`'s parameter rather than
        # pre-assigning `@cwd`, so its change detection sees the old directory.
        refresh cwd || @initial_cwd
      end

      # Opens the file manager, lets the user navigate, and yields the chosen
      # file path to the block (or `nil` if cancelled). Restores the previous
      # focus/visibility afterwards.
      def pick(cwd : String? = nil, &callback : String? ->)
        was_focused = focused?
        was_hidden = !style.visible?

        resume = -> {
          @pick_subs.off
          hide if was_hidden
          window.restore_focus unless was_focused
          request_render
        }

        @pick_subs.on(self, Crysterm::Event::FileSelected) do |e|
          resume.call
          callback.call e.path
        end

        @pick_subs.on(self, Crysterm::Event::Cancelled) do
          resume.call
          callback.call nil
        end

        refresh cwd
        show if was_hidden
        unless was_focused
          window.save_focus
          focus
        end
        request_render
      end

      # Activating an entry (Enter) navigates into directories and emits
      # `Event::FileSelected` for regular files.
      def activate_current
        super
        open_selected
      end

      # Cancelling (Escape) emits `Event::Cancelled` so `#pick` can resolve.
      def cancel_current
        super
        emit Crysterm::Event::Cancelled
      end

      private def open_selected
        return if @items.empty?
        # Resolve from the stored real name, not the decorated row text.
        name = @entry_names[current_index]?
        return unless name

        target = File.expand_path(name, @cwd)

        info = begin
          File.info(target, follow_symlinks: true)
        rescue
          return
        end

        @path = target

        if info.directory?
          # `#refresh` rolls `@cwd` back if `target` is unreadable and announces
          # the navigation itself only when it actually landed somewhere new, so a
          # failed entry emits no spurious `DirectoryChanged`.
          refresh target
        else
          emit Crysterm::Event::FileSelected, target
        end
      end

      private def home_dir : String
        Crysterm::Config.filemanager_home
      end
    end
  end
end
