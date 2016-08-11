module Knx; end

require 'knx/object_server'

class Knx::BaosLighting
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 12004
    descriptive_name 'KNX BAOS Lighting'
    generic_name :Lighting

    # Communication settings
    delay between_sends: 40
    wait_response false

    tokenize indicator: "\x06", callback: :check_length


    def on_load
        @os = KNX::ObjectServer.new
    end

    def connected
        req = @os.status(1).to_binary_s
        send req, priority: 0

        @polling_timer = schedule.every('50s') do
            logger.debug { "Maintaining connection" }
            send req, priority: 0
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
    # Arguments: preset_number, area_number, fade_time in millisecond
    #    Trigger for CBUS module compatibility
    #
    def trigger(area, number, fade = 1000)
        req = @os.action(area, number).to_binary_s
        send req
    end


    def lighting(group, state, application)
        val = is_affirmative? state
        req = @os.action(area, val).to_binary_s
        send req
    end


    def light_level(area, level)
        # Not available
    end



    def received(data, resolve, command)
        result = @os.read(data)
        if result.error == :no_error
            logger.debug { "Index: #{result.header.start_item}, Item Count: #{result.header.item_count}, Data: #{result.data}" }
        else
            logger.warn { "Error response: #{result.error} (#{result.error_code})" }
        end
    end


    protected


    def check_length(byte_str)
        if byte_str.length > 6
            header = KNX::Header.new(byte_str)
            if byte_str.length >= header.request_length
                return header.request_length
            end
        end
        false
    end
end

