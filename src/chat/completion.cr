module Crysterm
  module Chat
    # The completion model behind the chat input's trigger-key autocomplete
    # (`Widget::Chat::Autocomplete`): candidate `Item`s, grouped into one
    # `Source` per trigger character (`/` commands, `@` file mentions, `!`
    # shell history, `#` memory notes, …), all held in a `Registry` the popup
    # controller queries as the user types.
    #
    # Kept under `Crysterm::Chat` (not `Crysterm::Widget::Chat`) so an
    # application can build and populate its registry without pulling in the
    # widget layer.
    module Completion
      # What a candidate completes to — carried on each `Item` so a renderer
      # can decorate rows per kind while every trigger shares one menu.
      enum Kind
        # A slash command (`/help`, `/model`, …).
        Command
        # A file path, as inserted by an `@` mention.
        File
        # A shell command (`!` bash mode).
        Bash
        # A memory note (`#` prefix).
        Memory
        # Anything an application registers beyond the built-in vocabularies.
        Other
      end

      # One completion candidate. `name` is the text inserted on accept
      # (without the trigger character); `description` is the annotation shown
      # dimmed beside it in the menu.
      record Item, name : String, description : String = "", kind : Kind = Kind::Other

      # The candidates for one trigger character: a static `#items` list, an
      # optional dynamic `#provider` (called with the typed query — e.g. a file
      # index scan), or both. `Registry#complete` filters and ranks the union.
      class Source
        getter trigger : Char

        # Whether the trigger fires at any word start (`@`-mention style) or
        # only as the very first character of the buffer (`/`-command style).
        property? anywhere : Bool

        getter items : Array(Item)

        property provider : Proc(String, Array(Item))?

        # A case-folded (downcased) mirror of `#items`' names, indices aligned
        # with it, feeding `Completion.filter`'s case-insensitive matching.
        # Memoized so a keystroke's refilter doesn't re-downcase the whole
        # static list each time; provider results are dynamic and are folded
        # per call.
        @folded_names : Array(String)?

        def initialize(@trigger, @anywhere, @items = [] of Item, @provider = nil)
        end

        # Appends *new_items* to the static candidates, keeping the
        # folded-name memo in sync.
        def add_items(new_items : Enumerable(Item)) : Nil
          @items.concat new_items
          @folded_names = nil
        end

        # The unfiltered candidate union for *query*: the static items plus
        # whatever the provider yields for it. Returns `#items` itself (no
        # copy) when the provider is absent or contributes nothing.
        def candidates(query : String) : Array(Item)
          prov = @provider
          extra = prov ? prov.call(query) : nil
          return @items if extra.nil? || extra.empty?
          @items + extra
        end

        # The ranked completions for *query* — `Completion.filter` over
        # `#candidates`, reusing the memoized folded names for the static part
        # so only provider-contributed names are downcased per call.
        def completions(query : String) : Array(Item)
          prov = @provider
          extra = prov ? prov.call(query) : nil
          if extra.nil? || extra.empty?
            Completion.filter @items, query, folded: folded_names
          elsif query.empty?
            # `filter` would keep everything; skip building the folded union.
            @items + extra
          else
            folded = folded_names.dup
            extra.each { |item| folded << item.name.downcase }
            Completion.filter @items + extra, query, folded: folded
          end
        end

        private def folded_names : Array(String)
          folded = @folded_names
          # The size guard also catches growth through the exposed `#items`
          # array by callers holding its reference (in-place *replacement* of
          # an item is not detected — use `#add_items`/a fresh `Source`).
          if folded.nil? || folded.size != @items.size
            folded = @folded_names = @items.map &.name.downcase
          end
          folded
        end
      end

      # The trigger→candidates table the autocomplete controller consults:
      # which characters open the menu, and what each offers.
      #
      # ```
      # reg = Chat::Completion::Registry.new
      # reg.register '/', [
      #   Chat::Completion::Item.new("help", "Show help", :command),
      #   Chat::Completion::Item.new("model", "Switch model", :command),
      # ]
      # reg.register('@') { |q| file_index.matches(q) }
      # ```
      class Registry
        @sources = {} of Char => Source

        # Registers static *items* for *trigger*, appending when the trigger
        # already has a source (so independent features can each contribute
        # commands). *anywhere* controls where the trigger fires (see
        # `Source#anywhere?`); it defaults to word-start for `@` and
        # buffer-start for everything else, matching the chat prefix grammar.
        def register(trigger : Char, items : Enumerable(Item), *, anywhere : Bool = trigger == '@') : Source
          src = ensure_source trigger, anywhere
          src.add_items items
          src
        end

        # Registers a dynamic *provider* for *trigger* — called with the query
        # typed so far each time the menu filters. A repeat registration
        # replaces the previous provider (static items are unaffected).
        def register(trigger : Char, *, anywhere : Bool = trigger == '@', &provider : String -> Array(Item)) : Source
          src = ensure_source trigger, anywhere
          src.provider = provider
          src
        end

        # The source registered for *trigger*, or `nil`.
        def source?(trigger : Char) : Source?
          @sources[trigger]?
        end

        # The registered trigger characters.
        def triggers : Array(Char)
          @sources.keys
        end

        # The ranked completions for *query* under *trigger* (empty when the
        # trigger is unregistered). See `.filter`.
        def complete(trigger : Char, query : String) : Array(Item)
          src = @sources[trigger]? || return [] of Item
          src.completions query
        end

        private def ensure_source(trigger : Char, anywhere : Bool) : Source
          @sources[trigger] ||= Source.new(trigger, anywhere)
        end
      end

      # Filters *candidates* against *query*: case-insensitive, prefix matches
      # ranked before substring matches, source order within each rank — the
      # Claude-CLI matching contract (prefix/substring, deliberately not
      # fuzzy). An empty query keeps everything (the menu opens on the bare
      # trigger showing the full list).
      #
      # *folded*, when given, is a pre-downcased mirror of *candidates*' names
      # with aligned indices (see `Source`'s memo), skipping the per-call
      # downcase of every candidate.
      def self.filter(candidates : Array(Item), query : String, *, folded : Array(String)? = nil) : Array(Item)
        return candidates.dup if query.empty?
        q = query.downcase
        prefixed = [] of Item
        substringed = [] of Item
        candidates.each_with_index do |item, i|
          name = folded ? folded[i] : item.name.downcase
          if name.starts_with? q
            prefixed << item
          elsif name.includes? q
            substringed << item
          end
        end
        prefixed.concat substringed
      end
    end
  end
end
