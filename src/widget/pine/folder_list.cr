require "../../widget_pine_selectable_list"

module Crysterm
  class Widget
    module Pine
      # Pine/Alpine folder list: a selectable list of mail folders with their
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

      # <!-- widget-examples:capture v1 -->
      # ![FolderList screenshot](../../../tests/widget/pine/folder_list/folder_list.5s.apng)
      # <!-- /widget-examples:capture -->
      class FolderList < SelectableList(Folder)
        # Nested-name alias for the record type.
        alias Folder = ::Crysterm::Widget::Pine::Folder

        def initialize(
          folders : Array(Folder) = [] of Folder,
          **list,
        )
          super folders, **list
        end

        record_accessors folders, folder, Folder

        # Formats one folder into a name + count row.
        def format_row(item : Folder, index : Int32) : String
          count = case item.count
                  when 0 then "(empty)"
                  when 1 then "1 Message"
                  else        "#{item.count} Messages"
                  end
          "  #{item.name.ljust(28)}#{count}"
        end
      end
    end
  end
end
