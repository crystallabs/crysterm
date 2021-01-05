require "event_handler"

module Crysterm
    include EventHandler

    event DataEvent, data : String
    event WarningEvent, message : String

    event ResizeEvent
    event AttachEvent
    event DetachEvent

    event HideEvent
    event ShowEvent

    event BlurEvent
    event FocusEvent
    event DestroyEvent

    event RenderEvent
    event PreRenderEvent
    event PostRenderEvent
    event DrawEvent

    event SetContentEvent
    event ParsedContentEvent

    event ReparentEvent, element : Widget::Node?
    event AdoptEvent, element : Widget::Element
    event RemoveEvent, element : Widget::Element
end
