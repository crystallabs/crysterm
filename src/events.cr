module Crysterm
  # Convenience namespace for events — the events-side sibling of
  # `Crysterm::Widgets`:
  #
  #     include Crysterm::Events
  #
  #     button.on(Clicked) { |e| ... } # instead of Crysterm::Event::Clicked
  #
  # Carries one alias per event class in `Crysterm::Event` — nothing else — so
  # including it only shortens the names. (Including `Crysterm::Event` itself
  # would instead make the including type an event *emitter*: that module
  # includes `EventHandler`.)
  module Events
  end
end

# Populates `Crysterm::Events` with one alias per constant of the event
# catalog. Swept at `macro finished` so it covers every event regardless of
# require order (some events are declared beside the widgets that emit them).
# Must be at the top level — a `macro finished` nested in a module is not
# honored (same constraint as `DOM.fill_registry`).
macro finished
  module Crysterm::Events
    {% for name in Crysterm::Event.constants %}
      {% if Crysterm::Event.constant(name).is_a?(TypeNode) %}
        alias {{ name.id }} = ::Crysterm::Event::{{ name.id }}
      {% end %}
    {% end %}
  end
end
