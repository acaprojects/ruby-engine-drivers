module Aca; end
class Aca::LightingManual
    include ::Orchestrator::Constants

    # For use with meeting room logic, if triggers are not defined
    # Not really recommended for accurate feedback.
    # (Levels may need to be set across multiple groups, difficult to determine which preset is selected)

    descriptive_name 'ACA Manual Lighting Logic'
    generic_name :Lighting
    default_settings light_levels: [{
            zones: [],
            level: 0
        }]
    implements :logic


    def on_load
        on_update
    end

    def on_update
        @triggers = setting(:light_levels) || []
    end

    def trigger(_, preset)
        index = preset.to_i
        trigger = @triggers[index]

        if trigger
            trigger.each do |area|
                zones = area[:zones] || []
                level = area[:level]
                app = area[:channel]

                zones.each do |zone|
                    args = [zone, level]
                    args << app if app
                    system[:Lights].light_level(*args)
                end
            end
            logger.debug { "Light level #{index} called" }
        else
            logger.debug { "Light level #{index} not found / missing" }
        end
    end
end
