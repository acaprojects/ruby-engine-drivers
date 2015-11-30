module Shure; end
module Shure::Microphone; end


class Shure::Microphone::Mxw
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 2202
    descriptive_name 'Shure Microflex Microphone'
    generic_name :Mic

    tokenize indicator: '< ', delimiter: ' >'

    
    def on_load
        on_update
    end

    def on_update
        
    end

    def connected
        @polling_timer = schedule.every('60s') do
            logger.debug "-- Polling Mics"
            do_poll
        end
    end

    def disconnected
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end

    

    def received(data, resolve, command)
        logger.debug { "-- received: #{data}" }

        return :success
    end


    def do_poll
        # TODO
    end


    private


    def do_send(command, options = {})
        logger.debug { "-- sending: < #{command} >" }
        send("< #{command} >", options)
    end
end
