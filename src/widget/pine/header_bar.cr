module Crysterm
  class Widget
    module Pine
      class HeaderBar < Widget::Layout
        property title
        property section
        property subsection
        property info

        def initialize(
          height h = 1, width w = "100%",
          title_content = "TITLE", section_content = "SECTION", subsection_content = "SUBSECTION", info_content = "STATUS",
          title : Widget? = nil, section : Widget? = nil, subsection : Widget? = nil, info : Widget? = nil,
          **layout
        )
          super **layout, width: w, height: h

          @style = Style.new inverse: true

          @style_pl2 = Style.new inverse: true, padding: Padding.new(left: 2)
          @style_pr2 = Style.new inverse: true, padding: Padding.new(right: 2)

          # @title =      title ||      Widget::Box.new height: h, style: @style, width: 16, padding: Padding.new( left: 2, right: 2), content: "TITLE"
          # @section =    section ||    Widget::Box.new height: h, style: @style, width: "50%-16", content: "SECTION"
          # @subsection = subsection || Widget::Box.new height: h, style: @style, width: "50%-16", content: "SUBSECTION"
          # @info =       info ||     Widget::Box.new height: h, style: @style, width: 16, padding: Padding.new( left: 2, right: 2), content: "STATUS", align: Tput::AlignFlag::Right
          @title = Widget::Box.new height: h, align: Tput::AlignFlag::VCenter, style: @style_pl2, width: 16, content: title_content
          @section = Widget::Box.new height: h, align: Tput::AlignFlag::VCenter, style: @style, width: "50%-16", content: section_content
          @subsection = Widget::Box.new height: h, align: Tput::AlignFlag::VCenter, style: @style, width: "50%-16", content: subsection_content
          @info = Widget::Box.new height: h, align: Tput::AlignFlag::VCenter | Tput::AlignFlag::Right, style: @style_pr2, width: 16, content: info_content

          append @title, @section, @subsection, @info
        end
      end
    end
  end
end
