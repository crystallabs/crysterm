require "./abstract_item_view"
require "../mixin/item_view"

module Crysterm
  class Widget
    # File manager element.
    #
    # An `AbstractItemView` (a sibling of `List`, reusing the row machinery via
    # `Mixin::ItemView`) whose items are the entries of a directory. Selecting a
    # directory (with `Enter`) navigates into it; selecting a file emits
    # `Event::OpenFile`. Directory changes emit `Event::ChangeDir`, and each
    # (re)listing emits `Event::Refresh`.
    #
    # ```
    # fm = Widget::FileManager.new parent: window, keys: true, cwd: Dir.current
    # fm.refresh
    # fm.on(Crysterm::Event::OpenFile) { |e| puts e.path }
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

      # The directory the file manager was created in. `#reset` returns here
      # (Qt/Blessed: `reset` goes back to the originally-configured `cwd`, not
      # to wherever the user last navigated or selected).
      @initial_cwd : String

      # The most recently selected entry (directory or file), as an absolute
      # path.
      getter file : String

      # Optional label template. If it contains the literal `%path`, that token
      # is replaced with the current directory on every navigation.
      property label_format : String?

      # Real entry names (`".."`, `"foo"`, …), parallel to the rendered rows.
      # `#open_selected` resolves from these rather than the decorated row text,
      # which carries color tags and a `/`/`@` suffix that could mangle a
      # filename containing `{...}` or a trailing `@`.
      @entry_names = [] of String

      # The OpenFile/Cancel handlers live only for the duration of one `#pick`,
      # torn down together by `resume`.
      @pick_subs = Crysterm::Subscriptions.new

      def initialize(cwd : String? = nil, label : String? = nil, keys = nil, **list)
        # `keys` is absorbed here: an item view always enables key handling, so
        # forwarding it would duplicate the `keys:` arg passed to `super`.
        @cwd = cwd || Dir.current
        @initial_cwd = @cwd
        @file = @cwd
        @label_format = label

        super **list.merge({parse_tags: true})

        label.try { |l| set_label l.gsub("%path", @cwd) }
      end

      # The currently selected path (alias of `#file`).
      def path : String
        @file
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
          @cwd = cwd != home ? home : "/"
          return refresh
        rescue
          # Unreadable dir (e.g. `File::AccessDeniedError` on a `chmod 000`
          # directory): roll `@cwd` back so it, the `%path` label, and the shown
          # rows all stay on the last good directory rather than pointing at a
          # dir whose listing we never loaded. `open_selected` commits the label
          # and `ChangeDir` only after this returns with `@cwd == target`.
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
        set_items ordered.map(&.[:text])
        selekt 0
        request_render

        emit Crysterm::Event::Refresh

        self
      end

      # Resets the file manager back to its initial directory (or *cwd*, when
      # given) and reloads. Uses the construction-time directory, not `@file`
      # (the last-selected entry, which can be a regular file).
      def reset(cwd : String? = nil)
        @cwd = cwd || @initial_cwd
        refresh
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

        @pick_subs.on(self, Crysterm::Event::OpenFile) do |e|
          resume.call
          callback.call e.path
        end

        @pick_subs.on(self, Crysterm::Event::Cancel) do
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
      # `Event::OpenFile` for regular files.
      def enter_selected
        super
        open_selected
      end

      # Cancelling (Escape) emits `Event::Cancel` so `#pick` can resolve.
      def cancel_selected
        super
        emit Crysterm::Event::Cancel, ""
      end

      private def open_selected
        return if @items.empty?
        # Resolve from the stored real name (see `@entry_names`), not the
        # decorated row text.
        name = @entry_names[selected]?
        return unless name

        target = File.expand_path(name, @cwd)

        info = begin
          File.info(target, follow_symlinks: true)
        rescue
          return
        end

        @file = target

        if info.directory?
          old = @cwd
          # Attempt the listing before committing the navigation: `refresh target`
          # rolls `@cwd` back to `old` if `target` is unreadable. Announce the
          # navigation (label + `ChangeDir`) only when it actually landed on
          # `target`, so a failed entry updates nothing and emits no spurious
          # `ChangeDir` for a move that never happened.
          refresh target
          if @cwd == target
            @label_format.try { |fmt| set_label fmt.gsub("%path", target) if fmt.includes?("%path") }
            emit Crysterm::Event::ChangeDir, target, old
          end
        else
          emit Crysterm::Event::OpenFile, target
        end
      end

      private def home_dir : String
        Crysterm::Config.filemanager_home
      end
    end
  end
end
