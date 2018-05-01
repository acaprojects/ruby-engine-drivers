# frozen_string_literal: true

require 'shellwords'

module Shure; end
module Shure::Microphone; end

# Documentation: https://aca.im/driver_docs/Shure/MXA910+command+strings.pdf

class Shure::Microphone::Mxa
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    tcp_port 2202
    descriptive_name 'Shure Ceiling Array Microphone'
    generic_name :CeilingMic

    tokenize indicator: '< ', delimiter: ' >'

    default_settings({
        send_meter_levels: false
    })

    def on_load
        on_update
    end

    def on_update; end

    def connected
        schedule.every('60s') do
            logger.debug '-- Polling Mics'
            do_poll
        end

        query_all
        set_meter_rate(0) unless setting(:send_meter_levels)
    end

    def disconnected
        schedule.clear
    end


    def query_all
        do_send 'GET 0 ALL'
    end

    def query_device_id
        do_send 'GET DEVICE_ID', name: :device_id
    end

    def query_firmware
        do_send 'GET FW_VER', name: :firmware
    end

    def set_meter_rate(rate)
        do_send 'SET METER_RATE', rate.to_s, name: :meter_rate
    end


    # Mute commands
    def query_mute
        do_send 'GET DEVICE_AUDIO_MUTE'
    end

    def mute(val = true)
        state = is_affirmative?(val) ? 'ON' : 'OFF'
        do_send 'SET DEVICE_AUDIO_MUTE', state, name: :mute
    end

    def unmute
        mute false
    end


    # Preset commands
    def query_preset
        do_send 'GET PRESET'
    end

    def preset(number)
        do_send 'SET PRESET', number.to_s, name: :preset
    end


    # flash the LED for 30 seconds
    def flash
        do_send 'SET FLASH ON'
    end


    # LED Setup
    def query_led_state
        do_send 'GET DEV_LED_IN_STATE'
    end

    def led(on = true)
        led_state_muted on
        led_state_unmuted on
    end

    def query_led_colour_muted
        do_send 'GET LED_COLOR_MUTED'
    end

    # Supported colours: :RED, :GREEN, :BLUE, :PINK, :PURPLE, :YELLOW, :ORANGE, :WHITE
    def led_colour_muted(colour)
        do_send 'SET LED_COLOR_MUTED', colour.to_s.upcase, name: :muted_color
    end

    def query_led_colour_unmuted
        do_send 'GET LED_COLOR_UNMUTED'
    end

    def led_colour_unmuted(colour)
        do_send 'SET LED_COLOR_UNMUTED', colour.to_s.upcase, name: :unmuted_color
    end

    def query_led_state_unmuted
        do_send 'GET LED_STATE_UNMUTED'
    end

    def led_state_unmuted(on = true)
        state = is_affirmative?(on) ? 'ON' : 'OFF'
        do_send 'SET LED_STATE_UNMUTED', state
    end

    def query_led_state_muted
        do_send 'GET LED_STATE_MUTED'
    end

    def led_state_muted(on = true)
        state = is_affirmative?(on) ? 'ON' : 'OFF'
        do_send 'SET LED_STATE_MUTED', state
    end

    def received(data, resolve, command)
        logger.debug { "-- received: #{data}" }

        # Convert { some data here } to " some data here "
        # Then use shellsplit to capture the parts and remove whitespace
        resp = data.gsub(/[\{\}]/, '"').shellsplit.map(&:strip)

        # We want to ignore sample responses
        if resp[0] == 'SAMPLE'
            resp[1..-1].each_with_index do |level, index|
                self["output#{index + 1}"] = level.to_i
            end
            return :ignore
        end

        return :abort if resp[1] == 'ERR'

        # Check if the first value is a number - channel level details
        if resp[1] =~ /^[0-9]+$/
            chann = resp[1]
            param = resp[2]&.downcase
            value = resp[3]&.downcase

            self["#{param}_#{chann}"] = value
            return :success
        end

        # Global value details
        param = resp[1].downcase.to_sym
        value = resp[2]

        case param
        when :device_audio_mute then self[:muted] = value == 'ON'
        when :meter_rate, :preset then self[param] = value.to_i
        when :dev_led_state_muted then self[:led_muted] = value == 'ON'
        when :dev_led_state_unmuted then self[:led_unmuted] = value == 'ON'
        else
            self[param] = value&.downcase
        end

        :success
    end

    def do_poll
        query_device_id
    end


    private


    def do_send(*command, **options)
        cmd = "< #{command.join(' ')} >"
        logger.debug { "-- sending: #{cmd}" }
        send(cmd, options)
    end
end
