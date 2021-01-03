require "event_handler"

module Crysterm
    include EventHandler

    event DataEvent, data : String

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
end
