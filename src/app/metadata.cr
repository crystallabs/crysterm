module Crysterm
  class App
    # Meta data about the app.
    #
    # This data is similar to convenient metadata existing in Qt apps.
    module Metadata
      # Name of the app. If unset, defaults to the path of the currently running program.
      property app_name : String = Process.executable_path || PROGRAM_NAME

      # App version. If unset, defaults to Crystal app's VERSION string.
      property app_version : String = VERSION

      # Internet domain of the organization that wrote this app.
      property organization_domain : String = ""

      # Name of the organization that wrote this app. If unset, defaults to organization's internet domain.
      property organization_name : String { @organization_domain }
    end
  end
end
