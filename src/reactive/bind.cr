module Crysterm
  module Reactive
    # Binds a side effect to one or more signals. Whenever any of *signals*
    # changes, *block* runs and *owner*'s window is asked to repaint. The binding
    # runs once immediately, so *owner* reflects current state at bind time, and
    # is disposed automatically when *owner* emits `Event::Destroy`.
    #
    # Dependencies are **explicit**: you name the signals to watch, and the
    # watched set is fixed for the binding's life. For a side effect whose
    # dependency *set* changes between runs, use the re-tracking `Effect`.
    #
    # Returns the `Binding` so it can be disposed early by hand if needed.
    #
    # ```
    # count = Crysterm::Reactive::Signal.new 0
    # Crysterm::Reactive.bind(label, count) { label.content = "Count: #{count.value}" }
    # count.value = 5 # label.content is now "Count: 5"; a repaint is scheduled
    # ```
    def self.bind(owner : ::Crysterm::Widget, *signals : SignalBase, &block : ->) : Binding
      binding = Binding.new owner, block
      signals.each { |s| binding.watch s }
      owner.on(::Crysterm::Event::Destroy) { binding.dispose }
      binding.run
      binding
    end
  end
end
