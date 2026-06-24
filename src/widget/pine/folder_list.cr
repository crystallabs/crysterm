module Crysterm
  class Widget
    module Pine
      # The Pine/Alpine FOLDER LIST: a selectable list of mail folders with their
      # message counts.
      #
      # ```
      #   INBOX                      5 Messages
      #   Sent                      12 Messages
      #   Drafts                     1 Message
      # ```
      #
      # Navigate with the arrow keys; Enter opens the folder (runs its
      # `callback`).
      #
      # <!-- widget-examples:capture v1 -->
      # ![FolderList screenshot](../../../examples/widget/pine/folder_list/folder_list-capture.png)
      # <!-- /widget-examples:capture -->
      class FolderList < Widget::List
        # A single mail folder.
        class Folder
          # Folder name (e.g. `"INBOX"`).
          property name : String

          # Number of messages it contains.
          property count : Int32

          # Action invoked when the folder is opened.
          property callback : Proc(Nil)?

          def initialize(@name, @count = 0, *, @callback = nil)
          end
        end

        # The folders currently displayed, parallel to the list rows.
        getter folders = [] of Folder

        def initialize(
          folders : Array(Folder) = [] of Folder,
          **list,
        )
          super **list

          styles.selected = Style.new reverse: true

          set_folders folders

          on ::Crysterm::Event::ActionItem do |e|
            run_selected
          end
        end

        # Replaces the displayed folders.
        def set_folders(folders : Array(Folder))
          @folders = folders
          set_items folders.map { |f| format_folder f }
        end

        # The currently-selected folder, if any.
        def selected_folder : Folder?
          @folders[selected]?
        end

        # Opens the currently-selected folder.
        def run_selected
          selected_folder.try &.callback.try &.call
        end

        # Formats one folder into a name + count row.
        private def format_folder(f : Folder) : String
          count = case f.count
                  when 0 then "(empty)"
                  when 1 then "1 Message"
                  else        "#{f.count} Messages"
                  end
          "  #{f.name.ljust(28)}#{count}"
        end
      end
    end
  end
end
