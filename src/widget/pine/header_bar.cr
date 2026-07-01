module Crysterm
  class Widget
    module Pine
      # The reverse-video title bar shown at the top of every Pine/Alpine
      # window. It is divided into three zones:
      #
      # ```
      #   ALPINE 2.26   MESSAGE INDEX                 Folder: INBOX  5 Messages
      #   └─ title ──┘  └──── section ────┘          └─────── info ─────────┘
      # ```
      #
      # * `title`   — fixed-width left zone, usually the program name + version.
      # * `section` — flexible middle zone, the current window's name.
      # * `info`    — fixed-width right zone, right-aligned status (e.g. folder).
      #
      # Each zone is a `Widget::Box`; update them at runtime via
      # `header.section.content = "..."`, etc.
      #
      # <!-- widget-examples:capture v1 -->
      # ![HeaderBar screenshot](../../../tests/widget/pine/header_bar/header_bar.5s.apng)
      # <!-- /widget-examples:capture -->
      class HeaderBar < Widget::Box
        getter title : Widget::Box
        getter section : Widget::Box
        getter info : Widget::Box

        def initialize(
          height h = 1, width w = "100%",
          title_content = "", section_content = "", info_content = "",
          title_width = 16, info_width = 28,
          **opts,
        )
          super **opts, width: w, height: h

          # The three zones flow left-to-right; masonry reproduces the inline
          # arrangement from when this widget was a `Widget::Layout`. Set the
          # ivar directly (not `self.layout=`) since `@title`/`@section`/`@info`
          # aren't initialized yet.
          @layout = Crysterm::Layout::Masonry.new

          @style = Style.new reverse: true
          # Padding.new order is (left, top, right, bottom).
          style_pl2 = Style.new reverse: true, padding: Padding.new(2, 0, 0, 0)
          style_pr2 = Style.new reverse: true, padding: Padding.new(0, 0, 2, 0)

          section_width = "100%-#{title_width + info_width}"

          @title = Widget::Box.new(
            height: h, align: :vcenter,
            style: style_pl2, width: title_width, content: title_content,
          )
          @section = Widget::Box.new(
            height: h, align: :vcenter,
            style: @style, width: section_width, content: section_content,
          )
          @info = Widget::Box.new(
            height: h, align: {:vcenter, :right},
            style: style_pr2, width: info_width, content: info_content,
          )

          append @title, @section, @info
        end
      end
    end
  end
end
