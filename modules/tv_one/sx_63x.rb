module TvOne; end

class TvOne::Sx63x
    include ::Orchestrator::Constants

    descriptive_name 'TV One T1-SX HDMI Switcher'
    generic_name :Switcher
    wait_response false
    delay between_sends: 150

    def connected
        @polling_timer = schedule.every('60s') do
            logger.debug "Ensuring TVOne switcher is on"
            power true
        end

        login
    end
    
    def disconnected
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end

    def power(state)
        if is_affirmative?(state)
            send 'P1'
        else
            send 'P0'
        end
    end

    def switch_to(input)
        send "I#{input}"
    end

    def switch(map)
        map.each do |input|
            switch_to input
        end
    end


    def received(data, resolve, command)
        logger.debug { "TV One Switcher sent #{data}" }
        return :success
    end
end
