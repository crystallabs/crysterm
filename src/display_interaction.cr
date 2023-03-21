module Crysterm
  class Display
    # File related to interaction on the display

    @_keys_fiber : Fiber?

    # Sets up IO listeners for keyboard (and mouse, but mouse is currently unsupported).
    def listen
      # D O:
      # Potentially reset screen title on exit:
      # if !tput.rxvt?
      #  if !tput.vte?
      #    tput.set_title_mode_feature 3
      #  end
      #  manipulate_window(21) { |err, data|
      #    return if err
      #    @_original_title = data.text
      #  }
      # end

      # Listen for keys/mouse on input
      # if (@tput.input._our_input == 0)
      #  @tput.input._out_input = 1
      listen_keys
      # listen_mouse # TODO
      # else
      #  @tput.input._our_input += 1
      # end

      # TODO Do this if it's possible to get resize events on individual IOs.
      # Listen for resize on output
      # if (@output._our_output==0)
      #  @output._our_output = 1
      #  listen_output
      # else
      #  @output._our_output += 1
      # end
    end

    # Starts emitting `Event::KeyPress` events on key presses.
    #
    # Keys are listened for in a separate `Fiber`. There should be at most 1.
    def listen_keys
      return if @_keys_fiber
      @_keys_fiber = spawn {
        tput.listen do |char, key, sequence|
          emit Crysterm::Event::KeyPress.new char, key, sequence
        end
      }
    end
  end
end
