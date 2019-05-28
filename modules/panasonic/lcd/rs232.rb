# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'digest/md5'

module Panasonic; end
module Panasonic::LCD; end

# Documentation:
# * Protocol: https://aca.im/driver_docs/Panasonic/lcd_protocol2.pdf
# * Commands: https://aca.im/driver_docs/Panasonic/panasonic_commands.pdf

class Panasonic::LCD::Rs232
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    tcp_port 1024
    descriptive_name 'Panasonic LCD RS-232'
    generic_name :Display

    # Communication settings
    tokenize delimiter: "\x03"


    def on_load
        self[:power] = false
        self[:power_stable] = true  # Stable by default (allows manual on and off)

        # Meta data for inquiring interfaces
        self[:type] = :lcd

        # The projector drops the connection when there is no activity
        schedule.every('60s') { do_poll if self[:connected] }
        on_update
    end

    def on_update
        #@username = setting(:username) || 'dispadmin'
        #@password = setting(:password) || '@Panasonic'
    end

    def connected

    end

    def disconnected
    end

    COMMANDS = {
        power_on: 'PON',
        power_off: 'POF',
        power_query: 'QPW',
        input: 'IMS',
        volume: 'AVL',
        volume_query: 'QAV',
        audio_mute: 'AMT',
        audio_mute_query: 'QAM',
        current_input: 'QMI'
    }
    COMMANDS.merge!(COMMANDS.invert)

    #
    # Power commands
    #
    def power(state, opt = nil)
        self[:power_stable] = false
        if is_affirmative?(state)
            self[:power_target] = On
            do_send(:power_on, retries: 10, name: :power, delay: 10000, timeout: 15000)
            logger.debug "requested to power on"
            do_send(:power_query)
        else
            self[:power_target] = Off
            do_send(:power_off, retries: 10, name: :power, delay: 8000)
            logger.debug "requested to power off"
            do_send(:power_query)
        end
    end

    def power?(**options, &block)
        options[:emit] = block if block_given?
        do_send(:power_query, options)
    end

    #
    # Input selection
    #
    INPUTS = {
        hdmi1: 'HM1',
        hdmi: 'HM1',
        hdmi2: 'HM2',
        vga: 'PC1',
        dvi: 'DV1',
        hdbaset: 'DL1'
    }
    INPUTS.merge!(INPUTS.invert)

    def switch_to(input)
        input = input.to_sym
        return unless INPUTS.has_key? input

        # Projector doesn't automatically unmute
        unmute if self[:mute]

        logger.debug { "requested to switch to: #{input}" }
        do_send(:input, INPUTS[input], retries: 10, delay_on_receive: 2000).then do
            # Can't query current input
            self[:input] = input
        end
    end

    def input?
        do_send(:current_input)
    end

    #
    # Mute Audio
    #
    def mute_audio(val = true)
        actual = val ? 1 : 0
        logger.debug "requested to mute #{val}"
        do_send(:audio_mute, actual)    # Audio + Video
        do_poll
    end
    alias_method :mute, :mute_audio

    def unmute_audio
        mute false
    end
    alias_method :unmute, :unmute_audio

    def muted?
        do_send(:audio_mute_query)
    end

    def volume(level)
        # Unable to query current volume
        do_send(:volume, level.to_s.rjust(3, '0')).then { self[:volume] = level.to_i }
    end

    def volume?
        do_send :volume_query
    end

    def do_poll
        power?(priority: 0).then do
            if self[:power]
                input?
                volume?
                muted?
            end
        end
    end

    ERRORS = {
        ERR1: '1: Undefined control command',
        ERR2: '2: Out of parameter range',
        ERR3: '3: Busy state or no-acceptable period',
        ERR4: '4: Timeout or no-acceptable period',
        ERR5: '5: Wrong data length',
        ERRA: 'A: Password mismatch',
        ER401: '401: Command cannot be executed',
        ER402: '402: Invalid parameter is sent'
    }

    def received(data, resolve, command)        # Data is default received as a string
        logger.debug { "sent #{data} for #{command ? command[:data] : 'unknown'}" }

        # This is the ready response
        if data[0] == ' '
            # Ignore this as it is not a response, we can now make a request
            return :ignore
        end

        # remove the leading 00
        data = data[2..-1]

        # Error Response (00ER401)
        if data.start_with?('ER')
            error = data.to_sym
            self[:last_error] = ERRORS[error]

            # Check for busy or timeout
            if error == :ERR3 || error == :ERR4
                logger.warn "Display busy: #{self[:last_error]}"
                return :retry
            else
                logger.error "Display error: #{self[:last_error]}"
                return :abort
            end
        end

        cmd = COMMANDS[data]
        case cmd
        when :power_on
            self[:power] = true
            ensure_power_state
        when :power_off
            self[:power] = false
            ensure_power_state
        when '001'
            self[:power] = true
            ensure_power_state
        else
            res = data.split(':')[1]
            case command[:name]
            when :power_query
                self[:power] = res.to_i == 1
                ensure_power_state
            when :audio_mute_query
                self[:audio_mute] = res.to_i == 1
            when :volume_query
                self[:volume] = res.to_i
            when :current_input
                self[:input] = INPUTS[res]
            end
        end

        :success
    end


    protected


    def ensure_power_state
        if !self[:power_stable] && self[:power] != self[:power_target]
            power(self[:power_target])
        else
            self[:power_stable] = true
        end
    end

    def do_send(command, param = nil, **options)
        if param.is_a? Hash
            options = param
            param = nil
        end

        # Default to the command name if name isn't set
        options[:name] = command unless options[:name]
        # options[:disconnect] = true

        if param.nil?
            cmd = COMMANDS[command]
        else
            cmd = "#{COMMANDS[command]}:#{param}"
        end

        full_cmd = hex_to_byte('02') << cmd << hex_to_byte('030D')

        # Will only accept a single request at a time.
        send(full_cmd, options)
    end

end
