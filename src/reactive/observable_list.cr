module Crysterm
  module Reactive
    # A granular list mutation, carried by `Event::ListChange`.
    #
    # * `Insert` — `count` items were inserted starting at `index`.
    # * `Remove` — `count` items were removed starting at `index`.
    # * `Update` — the single item at `index` was replaced in place.
    # * `Reset`  — wholesale change (`clear`/`replace`); rebuild from scratch.
    #   `index`/`count` are unused (`0`).
    enum ListOp
      Insert
      Remove
      Update
      Reset
    end

    # Non-generic base carrying the event-emitter machinery, so `ObservableList(T)`
    # inherits `on`/`emit` without re-instantiating it per element type — same
    # pattern as `SignalBase`.
    abstract class ObservableListBase
      include EventHandler
    end

    # An observable, ordered collection. Mutating it emits a *granular*
    # `Event::ListChange` describing exactly what changed, so a bound item view
    # (`Reactive.bind_items`) patches the affected rows instead of rebuilding the
    # whole list. `T` is the element type — arbitrary application data; a render
    # block maps each element to display text at bind time.
    #
    # ```
    # todos = Crysterm::Reactive::ObservableList(String).new %w[buy milk]
    # Crysterm::Reactive.bind_items(list_widget, todos, &.itself)
    # todos << "walk dog" # appends exactly one row to list_widget
    # ```
    class ObservableList(T) < ObservableListBase
      include Enumerable(T)

      def initialize
        @array = [] of T
      end

      def initialize(initial : Enumerable(T))
        @array = initial.to_a
      end

      # --- reads ---

      def size : Int32
        @array.size
      end

      def empty? : Bool
        @array.empty?
      end

      def [](index : Int) : T
        @array[index]
      end

      def []?(index : Int) : T?
        @array[index]?
      end

      def each(& : T ->) : Nil
        @array.each { |e| yield e }
      end

      def to_a : Array(T)
        @array.dup
      end

      def first? : T?
        @array.first?
      end

      def last? : T?
        @array.last?
      end

      # --- mutations (each emits one ListChange) ---

      # Appends *item* to the end.
      def push(item : T) : self
        @array.push item
        emit_change ListOp::Insert, @array.size - 1, 1
        self
      end

      # :ditto:
      def <<(item : T) : self
        push item
      end

      # Inserts *item* before *index*.
      def insert(index : Int, item : T) : self
        @array.insert index, item
        emit_change ListOp::Insert, index.to_i, 1
        self
      end

      # Prepends *item*.
      def unshift(item : T) : self
        insert 0, item
      end

      # Appends every element of *other* in order (one `Insert` for the run).
      def concat(other : Enumerable(T)) : self
        arr = other.to_a
        return self if arr.empty?
        start = @array.size
        @array.concat arr
        emit_change ListOp::Insert, start, arr.size
        self
      end

      # Removes and returns the item at *index*.
      def delete_at(index : Int) : T
        item = @array.delete_at index
        emit_change ListOp::Remove, index.to_i, 1
        item
      end

      # Removes and returns the last item (`nil` if empty).
      def pop : T?
        return nil if @array.empty?
        delete_at @array.size - 1
      end

      # Removes and returns the first item (`nil` if empty).
      def shift : T?
        return nil if @array.empty?
        delete_at 0
      end

      # Replaces the item at *index* in place.
      def []=(index : Int, item : T) : T
        @array[index] = item
        emit_change ListOp::Update, index.to_i, 1
        item
      end

      # Removes everything (`Reset`).
      def clear : Nil
        return if @array.empty?
        @array.clear
        emit_change ListOp::Reset, 0, 0
      end

      # Replaces the whole contents with *other* (`Reset`).
      def replace(other : Enumerable(T)) : self
        @array = other.to_a
        emit_change ListOp::Reset, 0, 0
        self
      end

      private def emit_change(op : ListOp, index : Int32, count : Int32) : Nil
        emit ::Crysterm::Event::ListChange, op, index, count
      end
    end
  end
end
