module Crysterm
  abstract class CoreApplication
    @application_name : String = ""
    @application_version : String = "<unknown>"

    @organization_domain : String = ""
    @organization_name : String = ""

    #exiting->closing_down
  end
end
