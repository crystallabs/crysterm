module Crysterm
  module Macros
    # NOTE: method aliasing is provided by `Crystallabs::Helpers::Alias_Methods`
    # (included into `Widget` and the mixins that alias) — it copies every
    # overload's restrictions, so it is safe next to inherited same-name methods.

    # Defines a change-guarded property setter: bail if unchanged, otherwise
    # assign, mark the widget dirty, then emit *event*. The assign happens
    # *before* the emit so listeners observe the new value, not the old one.
    #
    # The backing ivar is `@name`. Pass *val_type* to type-annotate the argument.
    macro change_guarded_setter(name, event, val_type = nil)
      def {{ name.id }}=(val{% if val_type %} : {{ val_type.id }}{% end %})
        return if @{{ name.id }} == val
        @{{ name.id }} = val
        update
        emit ::Crysterm::Event::{{ event.id }}
      end
    end

    # Defines a repaint-on-change property: the repaint sibling of
    # `change_guarded_setter` (which marks dirty + emits) and `reactive_property`
    # (which fans out to reactive subscribers). The generated setter bails when the
    # value is unchanged, otherwise assigns, runs the optional *after* hook, and
    # schedules a repaint via `update!`, returning the new value:
    #
    # ```
    # def name=(value : Type) : Type
    #   return value if value == @name
    #   @name = value
    #   <after>        # only when given
    #   update!
    #   value
    # end
    # ```
    #
    # The backing ivar is `@name`. Two shapes, selected by *default*:
    #
    # * **Full property** (a non-nil *default* is given): also declares
    #   `@name : type = default` and a plain `#name` getter, so the whole property
    #   lives in one call.
    # * **Setter only** (*default* omitted): emits just the setter, for a property
    #   whose ivar and getter are already declared elsewhere (e.g. a `getter?`
    #   predicate, or an `initialize` parameter) — keep the existing
    #   `getter`/`getter?` line, it stays the source of the reader.
    #
    # *after* is an optional post-assign hook run **before** the unconditional
    # `update!` — deliberately scoped to hooks that do **not** themselves
    # schedule a repaint (`update_content`, `invalidate_css`). A hook that already
    # schedules one (`update`/`invalidate`/`invalidate_canvas`) would
    # double-schedule and must not be used here; route those through a plain
    # setter (or `change_guarded_setter`) instead. Assumes the including type is a
    # `Widget` (uses `update!`), like `change_guarded_setter`.
    macro repaint_property(name, type, default = nil, after = nil)
      {% if default != nil %}
        @{{ name.id }} : {{ type }} = {{ default }}

        def {{ name.id }} : {{ type }}
          @{{ name.id }}
        end
      {% end %}

      def {{ name.id }}=(value : {{ type }}) : {{ type }}
        return value if value == @{{ name.id }}
        @{{ name.id }} = value
        {% if after %} {{ after.id }} {% end %}
        update!
        value
      end
    end

    # Declares a `Reactive::Property`-backed widget property — the reactive
    # sibling of `change_guarded_setter`. Given
    # `reactive_property title : String = ""` it generates:
    #
    # * `#title_property` — the backing `Reactive::Property(String)`, created
    #   lazily on first use with the declared default (no allocation until
    #   touched). Bind against it (`Reactive.bind(dst, obj.title_property) { … }`).
    # * `#title` — reads the value; **tracks** the property as a dependency when
    #   read inside an `Effect`/`Computed`, so `obj.title` participates in
    #   auto-tracking just like a bare `Reactive::Property#value` read.
    # * `#title=` — change-guarded assign. On a real change it notifies the
    #   property's subscribers, `update`s, and schedules a repaint of the owning
    #   window, so a bare `obj.title = "x"` both fans out to bindings/effects and
    #   redraws the widget itself. Pass *event* to also emit a widget-level event
    #   (parity with `change_guarded_setter`).
    #
    # A default value is required (the property needs an initial value). Assumes the
    # including type is a `Widget` (uses `update`/`window?`), like
    # `change_guarded_setter`.
    #
    # Like `enum_property`, the `name : Type = default` argument reads as an
    # assignment to `ameba`, so prefix each call site with
    # `# ameba:disable Lint/UselessAssign`.
    macro reactive_property(decl, event = nil)
      {% raise "reactive_property #{decl.var} requires a default value" unless decl.value %}

      @{{ decl.var }} : ::Crysterm::Reactive::Property({{ decl.type }})?

      def {{ decl.var }}_property : ::Crysterm::Reactive::Property({{ decl.type }})
        @{{ decl.var }} ||= ::Crysterm::Reactive::Property({{ decl.type }}).new({{ decl.value }})
      end

      def {{ decl.var }} : {{ decl.type }}
        {{ decl.var }}_property.value
      end

      def {{ decl.var }}=(val : {{ decl.type }}) : {{ decl.type }}
        cell = {{ decl.var }}_property
        # Untracked guard read (`#peek`, not `#value`) so a setter called from
        # inside an effect doesn't spuriously depend on the property.
        return val if cell.peek == val
        cell.value = val
        update
        window?.try &.update
        {% if event %} emit ::Crysterm::Event::{{ event.id }} {% end %}
        val
      end
    end

    # Declares an empty-guarded collection property: a `getter name : type =
    # default` paired with a setter that rejects an *empty* assignment, falling
    # back to `default.dup` so the ivar is never left empty. An empty collection
    # here crashes the render fiber at read time (an out-of-range index, a
    # `sample` on nothing, a `% size` division by zero), so this macro guards
    # *emptiness* the way `change_guarded_setter`/`reactive_property` guard
    # *change*. The backing ivar is `@name`; the setter returns the stored value.
    #
    # Two shapes, selected by *reject_empty_entries*:
    #
    # * **Whole-empty** (default): only a wholly-empty assignment falls back to
    #   the default (Fire's `ramp`, Matrix's `pool`, Spray's `spark_colors`).
    # * **Reject-empty-entries** (`reject_empty_entries: true`): empty *elements*
    #   are dropped first (`value.reject(&.empty?)`), then the whole-empty test
    #   applies to what remains — for a collection whose entries are themselves
    #   indexed (Spray's `grow`, which reads `entry[0]`, so `""` is as fatal as an
    #   empty list).
    #
    # Like `reactive_property`, the `name : Type = default` argument reads as an
    # assignment to `ameba`, so prefix each call site with
    # `# ameba:disable Lint/UselessAssign`.
    macro nonempty_property(decl, reject_empty_entries = false)
      {% raise "nonempty_property #{decl.var} requires a default value" unless decl.value %}

      getter {{ decl.var }} : {{ decl.type }} = {{ decl.value }}

      def {{ decl.var }}=(value : {{ decl.type }}) : {{ decl.type }}
        {% if reject_empty_entries %}
          value = value.reject(&.empty?)
        {% end %}
        @{{ decl.var }} = value.empty? ? {{ decl.value }}.dup : value
      end
    end

    # Defines a per-Window pooled mouse-event factory: a nilable `@_<name>_event`
    # ivar plus a private `<name>_event(ev)` that lazily constructs one instance
    # of `Crysterm::Event::<klass>` and `reset`s it on every dispatch, so a
    # high-frequency mouse report doesn't heap-allocate a fresh event each time.
    macro pooled_mouse_event(name, klass)
      @_{{ name.id }}_event : Crysterm::Event::{{ klass.id }}?

      private def {{ name.id }}_event(ev : ::Tput::Mouse::Event, target : Widget? = nil) : Crysterm::Event::{{ klass.id }}
        (@_{{ name.id }}_event ||= Crysterm::Event::{{ klass.id }}.new(ev)).reset ev, target
      end
    end

    # Declares a *pinnable registry glyph* accessor pair: a nilable ivar with its
    # plain `setter`, plus a getter that answers the pinned value when one was
    # assigned and otherwise resolves from the central `Glyphs` registry at the
    # widget's effective tier. Given `pinnable_registry_glyph expanded_char,
    # TreeExpanded` it generates:
    #
    # ```
    # setter expanded_char : Char? = nil
    #
    # def expanded_char : Char
    #   @expanded_char || glyph(Glyphs::Role::TreeExpanded)
    # end
    # ```
    #
    # so `Glyphs.set`/an ASCII glyph tier retunes the unset ones toolkit-wide while
    # an explicit assignment pins that one marker. Two shapes:
    #
    # * **Registry role** (*role* given): the fallback is `glyph(Glyphs::Role::role)`,
    #   `.to_s`-ed when *type* is `String` (a one-`Char` role rendered as text).
    # * **Expression** (*fallback* given): any expression, for a marker composed of
    #   several glyphs (Mutt's `├─` tee) or of no glyph at all (its blank gap
    #   column). *role* is then omitted.
    #
    # The `pinnable_glyph` sibling (below) covers the *CSS-slot* family
    # instead: it names the accessor `<name>_char` and resolves a sub-control's
    # `glyph` property before the registry. Use that one whenever the glyph has
    # a sub-control to be styled through, this one for plain registry-backed
    # chrome.
    #
    # Like `repaint_property`, document the property with a doc comment above the
    # call. Assumes the including type is a `Widget` (uses `#glyph`).
    macro pinnable_registry_glyph(name, role = nil, type = Char, fallback = nil)
      {% raise "pinnable_registry_glyph #{name} needs a role or a fallback expression" if role == nil && fallback == nil %}

      setter {{ name.id }} : {{ type.id }}? = nil

      def {{ name.id }} : {{ type.id }}
        @{{ name.id }} || {% if fallback %}
          ({{ fallback }})
        {% else %}
          glyph(::Crysterm::Glyphs::Role::{{ role.id }}){% if type.stringify == "String" %}.to_s{% end %}
        {% end %}
      end
    end

    # Declares a pinnable, CSS-overridable single-char glyph accessor:
    # a `setter <name>_char : Char? = nil` paired with a
    # `#<name>_char : Char` getter that returns the pinned char when assigned,
    # else resolves *role* through the CSS *sub* sub-style slot, then the
    # `Glyphs` registry at the effective tier. The CSS-slot sibling of
    # `pinnable_registry_glyph` above — see the comparison there.
    # Two-slot fallbacks (a glyph resolved from more than one CSS sub-style,
    # e.g. `ScrollBar#trough_char`'s `::add-page`/`::groove` pair) stay
    # hand-rolled — this macro covers only the single-slot family.
    macro pinnable_glyph(name, role, sub)
      setter {{ name.id }}_char : Char? = nil

      # :ditto:
      def {{ name.id }}_char : Char
        @{{ name.id }}_char || glyph(Glyphs::Role::{{ role.id }}, style.raw_sub_style({{ sub }}))
      end
    end

    # Registers a handler for the event, named after the event itself.
    #
    # E.g.:
    # ```
    # handle Event::Attached
    # ```
    #
    # Expands into:
    #
    # ```
    # on(Event::Attached, ->handle_attached(Event::Attached)
    # ```
    macro handle(event, handler = nil)
      on({{ event }}, ->handle_{{ handler || (event.stringify.split("::")[-1].underscore.id) }}({{ event }}))
    end
  end
end
