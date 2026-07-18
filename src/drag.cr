module Crysterm
  # Action negotiated between a drag source and a drop target, mirroring the
  # desktop (XDND / Wayland data-device / HTML5) copy/move/link vocabulary.
  # `@[Flags]` since a source can advertise (`DragData#supported`) more than
  # one action at once (e.g. `Move | Copy`); `None` is provided by `Flags`.
  #
  # Crysterm reuses the desktop *data model* (this enum plus the MIME-typed
  # payload in `DragData`) without the window-to-window wire protocol — a TUI
  # owns no window and can't be an XDND peer.
  @[Flags]
  enum DragAction
    Move
    Copy
    Link
  end

  # Which input sensor is driving a drag. Same `DragSession` and source/target
  # events regardless, so a widget written for mouse drag-and-drop also works
  # under keyboard drag-and-drop with no extra code.
  enum DragSensor
    Mouse
    Keyboard
  end

  # Typed payload carried by a drag, modeled on the desktop data-transfer object
  # (HTML5 `DataTransfer`, Qt `QMimeData`). Content is keyed by MIME type so the
  # same drop target can consume an internal drag and a desktop file-drop
  # (delivered as `text/uri-list`) through one code path.
  #
  # For a *reposition* ("self-move") drag the payload is empty — the source just
  # edits its own geometry. For a *transfer* drag the source fills the payload
  # at `DragStart` and a different target consumes it on `Drop`.
  class DragData
    getter source : Widget
    # Actions the source is willing to perform (advertised at `DragStart`),
    # e.g. `DragAction::Move | DragAction::Copy` to advertise both.
    property supported : DragAction
    # The currently negotiated action (set by the target and/or modifier keys).
    property action : DragAction
    # Whether the current target has accepted the drag (re-asked each `DragOver`).
    property? accepted : Bool = false

    @items = {} of String => String

    def initialize(@source, @supported = DragAction::Move, @action = DragAction::Move)
    end

    def []=(type : String, data : String)
      @items[type] = data
    end

    def []?(type : String)
      @items[type]?
    end

    def [](type : String)
      @items[type]
    end

    def has?(type : String) : Bool
      @items.has_key? type
    end

    def types : Array(String)
      @items.keys
    end

    # Called by a drop target (from a `DragEnter`/`DragOver` handler) to signal
    # it will accept the drop, optionally pinning the action.
    def accept(action : DragAction? = nil)
      @accepted = true
      @action = action if action
    end

    # Withdraws acceptance. Called automatically before each `DragOver` so a
    # target must re-affirm every move (its answer can change with modifiers).
    def reject
      @accepted = false
    end
  end

  # State of one in-flight drag gesture. Owned by the `Window` (at most one at a
  # time — a drag is modal) and shared by both sensors. Coordinates are
  # absolute (window) cell positions.
  class DragSession
    getter source : Widget
    getter data : DragData
    getter sensor : DragSensor
    # Current candidate drop target: the topmost widget under the pointer (mouse
    # sensor) or the focused widget (keyboard sensor). `nil` if none.
    property target : Widget?
    # Current anchor position (pointer for mouse; the source's top-left, nudged
    # by arrow keys, for keyboard).
    property x : Int32
    property y : Int32
    # Offset of the anchor within the source at pickup, so repositioning keeps
    # the grabbed point under the pointer instead of snapping the corner to it.
    property offset_x : Int32 = 0
    property offset_y : Int32 = 0

    # A *discrete* drag advances by separate events rather than a held button:
    # the keyboard sensor, and the two-click mouse fallback for terminals that
    # don't report motion. (A continuous mouse drag is press-move-release.)
    property? discrete : Bool = false

    def initialize(@source, @data, @x, @y, @sensor)
    end
  end
end
