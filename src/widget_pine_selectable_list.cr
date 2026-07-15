require "./widget/list"

module Crysterm
  class Widget
    module Pine
      # Shared scaffolding for the Pine/Alpine selectable lists (`FolderList`,
      # `AddressBook`, `MessageIndex`, `MainMenu` and `Setup`).
      #
      # Each of those is a `Widget::List` that keeps a parallel array of *record*
      # objects (`T`) behind the visible text rows. The base provides what they
      # all share:
      #
      # * the selected row highlighted in reverse video,
      # * a backing `#records` array, replaced wholesale via `#records=`
      #   (which rebuilds the rows through `#format_row`),
      # * `#selected_record`, the record under the cursor, and
      # * activation on `Event::ActionItem` (Enter / click), which by default
      #   runs the selected record's `callback`.
      #
      # A concrete subclass:
      #
      # * fixes the record type, e.g. `class FolderList < SelectableList(Folder)`
      #   (Crystal forbids naming a *nested* type in a class's own superclass
      #   clause, so each record class is declared at `Pine` scope and re-exposed
      #   under its historical nested name with an `alias`),
      # * implements `#format_row(item, index)` to render one record as a row,
      # * optionally overrides `#activate` (what Enter does), `#selected_index`
      #   (when visible rows don't map 1:1 to records) or `#rows` (to inject
      #   extra rows, e.g. spacers).
      abstract class SelectableList(T) < Widget::List
        # The records currently displayed, parallel to the visible rows.
        # Named `records`, not `data`, to avoid colliding with `Widget#data`
        # (the unrelated `YAML::Any?` slot from `Mixin::Data`).
        getter records : Array(T)

        def initialize(data : Array(T) = [] of T, **list)
          # Assigned before `super` so the generic ivar is always initialized
          # (the compiler can't see the assignment through `#records=`).
          @records = data

          super **list

          # Pine highlights the whole selected row in reverse video.
          styles.selected = Style.new reverse: true

          self.records = data

          # Enter / click activates the current record.
          on ::Crysterm::Event::ActionItem do |_e|
            activate
          end
        end

        # Defines the typed accessor trio a concrete subclass exposes over the
        # generic `records`/`records=`/`selected_record`, named for its record
        # type: a `<plural>` reader, a `<plural>=` replacer, and a
        # `selected_<singular>` reader. *type* is the record class (`T`). E.g.
        # `record_accessors folders, folder, Folder` generates `#folders`,
        # `#folders=` and `#selected_folder`.
        macro record_accessors(plural, singular, type)
          # The {{plural.id}} currently displayed, parallel to the list rows.
          def {{plural.id}} : Array({{type}})
            records
          end

          # Replaces the displayed {{plural.id}}.
          def {{plural.id}}=({{plural.id}} : Array({{type}}))
            self.records = {{plural.id}}
          end

          # The currently-selected {{singular.id}}, if any.
          def selected_{{singular.id}} : {{type}}?
            selected_record
          end
        end

        # Replaces the displayed records and rebuilds the visible rows.
        def records=(data : Array(T))
          @records = data
          self.items = rows(data)
        end

        # The record under the selection, if any.
        def selected_record : T?
          @records[selected_index]?
        end

        # Maps the selected *row* to the index of its record in `#records`. The
        # default is 1:1; override when rows and records don't line up (e.g.
        # `MainMenu`, which interleaves blank spacer rows).
        protected def selected_index : Int32
          selected
        end

        # Builds the visible row strings from *data*. The default renders one row
        # per record via `#format_row`; override to inject extra rows.
        protected def rows(data : Array(T)) : Array(String)
          data.map_with_index { |item, i| format_row item, i }
        end

        # Renders one record into its row string. *index* is the record's 0-based
        # position in `#records` (used e.g. for message numbering).
        abstract def format_row(item : T, index : Int32) : String

        # Invoked on `Event::ActionItem` (Enter / click). By default it runs the
        # selected record's `callback`; override for different behavior (e.g.
        # `Setup`, which toggles instead).
        def activate
          selected_record.try &.callback.try &.call
        end

        # Activates the currently-selected record. Subclasses may override
        # `#activate` for different behavior (e.g. `Setup`, which toggles
        # instead of invoking a callback).
        def run_selected
          activate
        end

        # Template-method hook: whether pressing the space bar toggles the
        # current row. When it returns `true`, the shared `#on_keypress` handles
        # `Space → #toggle_selected` and consumes the key; otherwise Space falls
        # through to the inherited list handling. Defaults to `false` (most lists
        # don't toggle); toggling subclasses override it with their own guard
        # (e.g. `Setup` always, `OptionList` when the selected option is a
        # `Toggle`, `ListSelect` in multi mode).
        protected def space_toggles? : Bool
          false
        end

        # Toggles the current row. A no-op hook by default; toggling subclasses
        # (`Setup`, `OptionList`, `ListSelect`) override it. Invoked from
        # `#on_keypress` only when `#space_toggles?` returns `true`.
        def toggle_selected
        end

        # Shared key handling: space-bar toggling (gated by `#space_toggles?`) on
        # top of the inherited arrow/Enter/paging navigation. Subclasses that
        # need extra keys (e.g. `OptionList`'s inline editing) override
        # `#on_keypress`, handle their keys, then `super` here.
        def on_keypress(e)
          if e.char == ' ' && space_toggles?
            toggle_selected
            e.accept
            return
          end
          super
        end
      end
    end
  end
end
