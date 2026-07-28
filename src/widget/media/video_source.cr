require "pnggif"
require "../media"

# Crysterm-side adapter for `PNGGIF::VideoSource`, the ffmpeg/ffprobe video →
# frames decoder that moved into the pnggif shard (REARRANGE R-34). The shard
# takes plain parameters (with `DEFAULT_*` constants as defaults) where this
# module used to read `Crysterm::Config`; the redefinitions below reinstate
# those config values as the parameter defaults via `previous_def`, so every
# existing call site (`Media::Base`'s stream open/mode probe, `Media.new`'s
# decode pipeline, `Widget::Video`) behaves exactly as before. The
# `Media::VideoSource` alias keeps all call sites compiling unchanged.
module PNGGIF
  module VideoSource
    # The shard's `Decode` strategy matching the current `media.video_decode`
    # config value.
    def config_decode : Decode
      case Crysterm::Config.media_video_decode
      in .auto?   then Decode::Auto
      in .eager?  then Decode::Eager
      in .stream? then Decode::Stream
      end
    end

    # `#mode` with the `media.video_decode` / `video.max_frames` config values
    # as defaults.
    def mode(file : String, decode : Decode = config_decode,
             max_frames : Int32 = Crysterm::Config.video_max_frames) : Mode
      previous_def
    end

    # `#decode` with the `video.max_size` / `video.fps` / `video.max_frames`
    # config values as defaults.
    def decode(file : String,
               cap : Int32 = Crysterm::Config.video_max_size,
               max_fps : Float64 = Crysterm::Config.video_fps,
               max_frames : Int32 = Crysterm::Config.video_max_frames) : PNGGIF::PNG?
      previous_def
    end

    class Stream
      # `Stream.open` with the `video.max_size` / `video.fps` config values as
      # defaults.
      def self.open(file : String,
                    cap : Int32 = Crysterm::Config.video_max_size,
                    max_fps : Float64 = Crysterm::Config.video_fps) : Stream?
        previous_def
      end
    end
  end
end

module Crysterm
  class Widget
    module Media
      alias VideoSource = PNGGIF::VideoSource
    end
  end
end
