# encoding: US-ASCII

module Biamp; end

# Documentation: https://aca.im/driver_docs/Biamp/tesira_commands.pdf

require 'shellwords'
require 'protocols/telnet'

class Biamp::Tesira
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 23 # Telnet
    descriptive_name 'Biamp Tesira'
    generic_name :Mixer

    # Communication settings
    tokenize delimiter: "\r\n",
             wait_ready: /login:|server/i

    # Nexia requires some breathing room
    delay between_sends: 30, on_receive: 30

    default_settings({
        no_password: true,
        username: 'default',
        password: 'default'
    })


    def on_load
        # Implement the Telnet protocol
        defaults timeout: 15000
        new_telnet_client
        config before_buffering: proc { |data|
            @telnet.buffer data
        }, wait_ready_timeout: 15000
    end

    def on_unload
    end

    def on_update
    end


    def connected
        # Echo off
        echo_off = Protocols::Telnet::IAC + Protocols::Telnet::DONT + Protocols::Telnet::OPT_ECHO
        send(echo_off, wait: false, delay: 200)

        if setting(:no_password)
            do_send (setting(:username) || :admin), wait: false, delay: 200, priority: 98
            do_send setting(:password), wait: false, delay: 200, priority: 97
        end
        do_send "SESSION set verbose false", priority: 96

        schedule.every('60s') do
            do_send "DEVICE get serialNumber", priority: 0
        end
    end

    def disconnected
        # Ensures the buffer is cleared
        new_telnet_client

        schedule.clear
    end


    def preset(number_or_name)
        if number_or_name.is_a? Integer
            do_send "DEVICE recallPreset #{number_or_name}"
        else
            do_send build(:DEVICE, :recallPresetByName, number_or_name)
        end
    end
    alias_method :trigger, :preset
        
    def start_audio
        do_send "DEVICE startAudio"
    end

    def reboot
        do_send "DEVICE reboot"
    end

    def get_aliases
        do_send "SESSION get aliases"
    end

    MIXERS = {
        matrix: :crosspointLevelState,
        mixer: :crosspoint
    }

    # {1 => [2,3,5], 2 => [2,3,6]}, true
    # Supports Standard, Matrix and Automixers
    # Who thought having 3 different types was a good idea? FFS
    def mixer(id, inouts, mute = false, type = :matrix)
        value = is_affirmative?(mute)
        type = type.to_sym
        mixer_type = MIXERS[type] || type

        if inouts.is_a? Hash
            inouts.each do |input, out|
                Array(out).each do |output|
                    do_send build(id, :set, mixer_type, input, output, value)
                end
            end
        else # assume array (auto-mixer)
            inouts.each do |input|
                do_send build(id, :set, mixer_type, input, value)
            end
        end
    end

    FADERS = {
        fader: :level,
        matrix_in: :inputLevel,
        matrix_out: :outputLevel,
        matrix_crosspoint: :crosspointLevel
    }
    FADERS.merge!(FADERS.invert)
    def fader(fader_id, level, index = 1, type = :fader)
        # value range: -100 ~ 12
        type = type.to_sym
        fader_type = FADERS[type] || type

        indicies = Array(index)
        Array(fader_id).each do |fad|
            indicies.each do |i|
                do_send build(fad, :set, fader_type, i, level), type: :fader
            end
        end
    end
    # Named params version
    def faders(ids:, level:, index: 1, type: :fader, **_)
        fader(ids, level, index, type)
    end

    MUTES = {
        fader: :mute,
        matrix_in: :inputMute,
        matrix_out: :outputMute
    }
    MUTES.merge!(MUTES.invert)
    def mute(fader_id, val = true, index = 1, type = :fader)
        value = is_affirmative?(val)
        type = type.to_sym
        mute_type = MUTES[type] || type

        indicies = Array(index)
        Array(fader_id).each do |fad|
            indicies.each do |i|
                do_send build(fad, :set, mute_type, i, value), type: :mute
            end
        end
    end
    # Named params version
    def mutes(ids:, muted: true, index: 1, type: :fader, **_)
        mute(ids, muted, index, type)
    end

    def unmute(fader_id, index = 1, type = :fader)
        mute(fader_id, false, index, type)
    end

    def query_fader(fader_id, index = 1, type = :fader)
        type = type.to_sym
        fad_type = FADERS[type] || type

        do_send build(Array(fader_id)[0], :get, fad_type, Array(index)[0]), type: :fader
    end
    # Named params version
    def query_faders(ids:, index: 1, type: :fader, **_)
        query_fader(ids, index, type)
    end

    def query_mute(fader_id, index = 1, type = :fader)
        type = type.to_sym
        mute_type = MUTES[type] || type

        do_send build(Array(fader_id)[0], :get, mute_type, Array(index)[0]), type: :mute
    end
    # Named params version
    def query_mutes(ids:, index: 1, type: :fader, **_)
        query_mute(ids, index, type)
    end


    def received(data, resolve, command)
        if data[0] == '-'
            if command
                logger.warn "Tesira returned #{data} for #{command[:data]}"
            else
                logger.debug { "Tesira responded #{data}" }
            end
            return :abort
        end

        logger.debug { "Tesira responded #{data}" }
        result = Shellwords.split data

        if command && command[:type]
            request = Shellwords.split command[:data]

            # Value is either in request or response
            temp_val = case request[1].to_sym
            when :get
                result[-1]
            when :set
                request[-1]
            else
                return :success
            end

            # We need to coerce the actual value type
            value = if temp_val == 'true'
                true
            elsif temp_val == 'false'
                false
            elsif temp_val.include? '.'
                temp_val.to_f
            else
                temp_val.to_i
            end

            # Lets set the variable
            case command[:type]
            when :fader
                fad = request[2].to_sym
                type = FADERS[fad] || fad
                self["#{type}#{request[0]}_#{request[3]}"] = value
            when :mute
                fad = request[2].to_sym
                type = MUTES[fad] || fad
                self["#{type}#{request[0]}_#{request[3]}_mute"] = value
            end
        end

        return :success
    end


    protected


    def new_telnet_client
        @telnet = Protocols::Telnet.new do |data|
            send data, priority: 99, wait: false
        end
    end

    def build(*args)
        cmd = ''
        args.each do |arg|
            data = arg.to_s
            next if data.blank?
            cmd << ' ' if cmd.length > 0

            if data.include? ' '
                cmd << '"'
                cmd << data
                cmd << '"'
            else
                cmd << data
            end
        end
        cmd
    end

    def do_send(command, options = {})
        logger.debug { "requesting #{command}" }
        send @telnet.prepare(command), options
    end
end
