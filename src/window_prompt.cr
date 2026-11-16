module Crysterm
  class Window
    # Prompts for a line of text and **returns** it, instead of delivering it to
    # a callback: the calling fiber parks until the user answers, while the
    # event loop keeps running and drawing. An `InputDialog` is presented with
    # *label* (the field starting at *value*); the answer is the entered string,
    # or `nil` when the user cancelled.
    #
    # This is the sequential spelling of `Widget::InputDialog.read` — several
    # questions in a row read as straight-line code instead of nesting one
    # callback inside the next:
    #
    # ```
    # spawn do
    #   to = window.prompt "To: "
    #   next unless to
    #   subject = window.prompt "Subject: "
    #   next unless subject
    #   compose to, subject
    # end
    # ```
    #
    # **Must be called off the render and input fibers** — see
    # `#reject_blocking_fiber`. A key handler runs *on* the input fiber, so wrap
    # the sequence in `spawn`, as above.
    def prompt(label : String, value : String = "") : String?
      reject_blocking_fiber "prompt"
      answer = ::Channel(String?).new 1
      # The dialog is built on the render fiber, keeping widget mutation there
      # even though the caller is some arbitrary fiber. A destroyed window runs
      # no posted job, so nothing would ever answer: that reads as a cancel.
      await_answer(answer, nil) { Widget::InputDialog.read(self, label, value) { |v| answer.send v } }
    end

    # Asks *question* and **returns** the answer — `true` for the affirmative
    # button, `false` for the negative one or a dismissal — parking the calling
    # fiber until then. The `MessageBox.ask` twin of `#prompt`, with the same
    # fiber rule.
    #
    # ```
    # spawn do
    #   window.close if window.ask "Quit without saving?"
    # end
    # ```
    def ask(question : String) : Bool
      reject_blocking_fiber "ask"
      answer = ::Channel(Bool).new 1
      # As in `#prompt`: with the window destroyed, a dismissal.
      await_answer(answer, false) { Widget::MessageBox.ask(self, question) { |v| answer.send v } }
    end

    # The cancellations of the `#prompt`/`#ask` callers parked for an answer.
    # `#destroy` runs them (`#release_answer_waiters`): a job still queued is
    # dropped with the window and an open dialog goes down with it, so no
    # answer would come.
    @answer_releases = [] of Proc(Nil)

    # Posts *job*, which presents the dialog that answers into *answer*, and
    # parks the calling fiber for that answer. Returns *cancelled* when the
    # window is destroyed first — before the job is queued, while it waits in
    # the queue, or with the dialog open.
    private def await_answer(answer : ::Channel(T), cancelled : T, &job : Proc(Nil)) : T forall T
      release = -> do
        # The channel holds one answer; with one already in, this is dropped.
        select
        when answer.send(cancelled)
        else
        end
        nil
      end
      @answer_releases << release
      begin
        return cancelled unless post?(&job)
        answer.receive
      ensure
        @answer_releases.delete release
      end
    end

    # Wakes every `#prompt`/`#ask` caller still parked, as cancelled.
    protected def release_answer_waiters : Nil
      while release = @answer_releases.shift?
        release.call
      end
    end

    # Raises unless the current fiber may be parked until the user answers.
    #
    # Two fibers must keep running for a dialog to appear and be answerable: the
    # render fiber (which draws it) and the device's input fiber (which delivers
    # the keys). Parking either deadlocks the application, so *what* refuses to
    # run there and says how to fix it, rather than hanging.
    private def reject_blocking_fiber(what : String) : Nil
      current = Fiber.current
      # The render fiber is the one running `render_loop` — which also runs the
      # `#post` jobs, outside any frame — or the one building a frame right now
      # (a direct `#repaint`).
      on_render = current.same?(@_render_loop_fiber) || (in_render? && current.same?(@in_render_fiber))
      on_input = current.same? @screen.input_fiber?
      return unless on_render || on_input
      raise "Window##{what} parks the calling fiber until the user answers, so it cannot run on the " \
            "#{on_render ? "render" : "input"} fiber (an event handler runs on the input fiber). " \
            "Wrap the call in `spawn { ... }`."
    end
  end
end
