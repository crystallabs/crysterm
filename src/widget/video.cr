require "../widget_media_base"
require "../widget_media_video_source"

module Crysterm
  class Widget
    # Plays a video file in the terminal.
    #
    # Video is **not** a backend of its own. A frame decoder
    # (`Media::VideoSource`, via `ffmpeg`/`ffprobe`) turns the file into
    # animation frames, and one of the existing `Widget::Media` backends —
    # Kitty, Sixel, Glyph or Ansi, picked by `Media.resolve(Content::Video)` for
    # the current terminal and honoring the `image.exclude` umask — renders them
    # like an animated GIF. `Video.new` is a thin factory returning the resolved
    # `Media::Base` pointed at the video file; everything else (animation loop,
    # resize, `#play`/`#pause`/`#stop`) is the image machinery.
    #
    # ```
    # vid = Widget::Video.new file: "clip.mp4", width: 40, height: 20, parent: window
    # ```
    #
    # Requires `ffmpeg` and `ffprobe` on `PATH`; without them (or on a decode
    # error) the chosen backend shows its normal "could not load" state. Eager
    # decoder — see `Media::VideoSource` for the memory caveat on long clips.
    module Video
      # Builds the best video-capable image backend for the current terminal and
      # loads *file* into it. Resolution order: an explicit *type*, then an
      # explicit (non-`auto`) `image.backend` pin, then
      # `Media.resolve(Content::Video)` for the terminal.
      def self.new(*, file : String? = nil, type : Media::Type? = nil, **opts) : Media::Base
        # Resolve `Content::Video` ourselves: `default_type` only picks the video
        # ranking from a *file* detected as a video, but this is the video entry
        # point regardless (e.g. a nil file constructed now, loaded later).
        # `Media.resolve` applies the `media.backend` pin / `media.exclude` /
        # capability ranking uniformly, so no `auto?` special-case is needed.
        type ||= Media.resolve(Media::Content::Video)
        Media.new(**opts.merge(type: type, file: file))
      end
    end
  end
end
