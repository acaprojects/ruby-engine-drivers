module Philips; end


class Philips::Dynalite
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    

    def on_load
        #
        # Setup constants
        #
        defaults({
            :wait => false,
            :delay => 0.4
        })
    end

    def connected
        @polling_timer = schedule.every('1m') do
            logger.debug "-- Dynalite Maintaining Connection"
            get_current_preset(1)    # preset for area 1
        end
    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #    Hence the check if timer is nil here
        #
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end
    
    
    #
    # Arguments: preset_number, area_number, fade_time in 50 millisecond increments
    #    Trigger for CBUS module compatibility
    #
    def trigger(area, number, fade = 2)
        # 0,1,2,3 then a,b,c,d for 4,5,6,7
        self[:"area#{area}"] = number
        area = area.to_i
        number = number.to_i
        fade = fade.to_i

        number = number - 1
        bank = number / 8
        number = number - (bank * 8)

        fade *= 50

        if number > 3
            number = number - 4 + 0x0A
        end
                                                       #high fade   #join (currently all in group)
        command = [0x1c, area & 0xFF, fade & 0xFF, number & 0xFF, (fade >> 8) & 0xFF, bank, 0xFF]

        do_send(command)
    end
    # 200 trigger 1 == join, 200 trigger 4 == unjoin


    def get_current_preset(area)                    # channel number
        command = [0x1c, area.to_i & 0xFF, 0, 0x63, 0, 0, 0xFF]
        do_send(command)
    end


    def light_level(area, level, fade = 0.1, channel = 255)
        fade = (fade * 100).to_i

        # Levels
        #0x01 == 100%
        #0xFF == 0%
        level = 100 - level                    # Inverse
        level = (level / 100.0 * 255.0).to_i    # Move into 255 range
        level = 1 if level <= 0                 # 1 == 100%
        level = 255 if level > 255                # 255 == 0%

        command = [0x1c, area & 0xFF, channel & 0xFF, 0x71, level, fade & 0xFF, 0xFF]
        do_send(command)
    end


    def get_light_level(area)
        do_send([0x1c, area.to_i & 0xFF, 0xFF, 0x61, 0, 0, 0xFF])
    end


    def increment_level(area)
        do_send([0x1c, area.to_i & 0xFF, 100, 6, 0, 0, 0xFF])
    end


    def decrement_level(area)
        do_send([0x1c, area.to_i & 0xFF, 100, 5, 0, 0, 0xFF])
    end
    
    
    
    def received(data, resolve, command)
        logger.debug "from dynalite 0x#{byte_to_hex(data)}--"
        
        data = str_to_array(data)

        if data[0] == 0x1c
            # 0-3, A-D
            if [0, 1, 2, 3, 10, 11, 12, 13].include?(data[3])
                number = data[3]
                number -= 0x0A + 4 if number > 3
                number += data[5] * 8 + 1
                self[:"area#{data[1]}"] = number

            elsif data[3] == 0x60
                level = data[4]
                level = 0 if level <= 1

                level = (level / 255.0 * 100.0).to_i    # Move into 0..100 range

                level = 100 - level
                self[:"area#{data[1]}_level"] = level
            end
        end

        :success
    end
    
    
    protected
    
    
    def do_send(command, options = {})
        #
        # build checksum
        #
        check = 0
        command.each do |byte|
            check = check + byte
        end
        check -= 1
        check = ~check
        check = "%x" % check
        check = check[-2, 2]
        check = check.to_i(16)

        #
        # Add checksum to command
        command << check
        command = array_to_str(command)
        
        send(command, options)

        logger.debug "to dynalite: 0x#{byte_to_hex(command)}--"
    end
end

