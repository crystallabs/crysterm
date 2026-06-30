require "../filemanager"

module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine FILE BROWSER: a `Widget::FileManager` pre-dressed in the
      # Pine look. Browse a directory with the arrow keys; Enter navigates into a
      # directory or opens (emits `Event::OpenFile` for) a file.
      #
      # This is a thin subclass: it adds no file logic of its own. It only flips
      # the defaults so a bare `FileBrowser.new` already looks and behaves like
      # Pine — the selected row is drawn in full-width reverse video, and keyboard
      # navigation is on. It stays completely generic (no email semantics); the
      # base `FileManager` does all the work (see `#refresh`, `#open_selected`,
      # `#cwd`, `#file` and `Event::OpenFile` / `Event::ChangeDir` /
      # `Event::Refresh`).
      #
      # ```
      # fb = Crysterm::Widget::Pine::FileBrowser.new parent: screen, cwd: Dir.current
      # fb.refresh
      # fb.on(Crysterm::Event::OpenFile) { |e| puts e.path }
      # fb.focus
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![FileBrowser screenshot](../../../tests/widget/pine/file_browser/file_browser.5s.apng)
      # <!-- /widget-examples:capture -->
      class FileBrowser < Widget::FileManager
        def initialize(cwd : String? = nil, label : String? = nil, keys = true, **list)
          super cwd, label, keys, **list

          # Pine highlights the whole selected row in reverse video.
          styles.selected = Style.new reverse: true
        end
      end
    end
  end
end
