load File.expand_path('./protocol3000.rb', File.dirname(__FILE__))

# These are UDP controlled and use the route command instead of AV, VID, AUD etc

class Kramer::Switcher::Presentation < Kramer::Switcher::Protocol3000

    def on_update
        super

        @default_type = setting(:route_type) || :audio_video
    end

    def switch(map, out = nil)
        map = {map => out} if out
        route(map, @default_type)
    end
    alias_method :switch_video, :switch

end
