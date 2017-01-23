module Shure; end
module Shure::Microphone; end


class Shure::Microphone::Mxw
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 2202
    descriptive_name 'Shure Microflex Microphone'
    generic_name :CeilingMic

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


    def get_device_id
        do_send 'GET DEVICE_ID'
    end


    # Mute commands
    def query_mute
        do_send 'GET DEVICE_AUDIO_MUTE'
    end

    def mute(val = true)
        state = val ? 'ON' : 'OFF'
        do_send "SET DEVICE_AUDIO_MUTE #{state}", name: :mute
    end

    def unmute
        mute false
    end

    # Preset commands
    def query_preset
        do_send 'GET PRESET'
    end

    def preset(number)
        do_send "SET PRESET #{number}", name: :preset
    end

    # flash the LED for 30 seconds
    def flash
        'SET FLASH ON'
    end


    def received(data, resolve, command)
        logger.debug { "-- received: #{data}" }

        resp = data.split(' ')
        case resp[1].to_sym
        when :DEVICE_AUDIO_MUTE
            self[:muted] = resp[2] == 'ON'
        when :PRESET
            self[:preset] = resp[2].to_i
        when :DEVICE_ID
            self[:device_id] = resp[2]
        end

        return :success
    end


    def do_poll
        get_device_id
    end


    private


    def do_send(command, options = {})
        logger.debug { "-- sending: < #{command} >" }
        send("< #{command} >", options)
    end
end
