module Crysterm
  abstract class CoreApplication

    class Options
      Toka.mapping({
        colors: {
          #short: ['c'],
          #long: ["colors"],
          type: Int32?,
          default: nil,
          description: "Number of colors to use. If left at nil, will be autodetected.",
        }
      }, {
        banner: Crysterm::CoreApplication.about,
        footer: "",
        help: true,
        color: true,
      })
    end

  end
end
