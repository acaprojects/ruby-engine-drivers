module Lg; end
module Lg::Lcd; end


# TCP Port: 9761
# This device does not hold the connection open. Must be configured as makebreak
class Lg::Lcd::ModelLs5
    include ::Orchestrator::Constants    # these provide optional helper methods
    include ::Orchestrator::Transcoder   # (not used in this module)


    tokenize delimiter: 'x'
    delay between_sends: 150


    def on_load
        @polling_timer = schedule.every('40s') do
            # No point polling if we can't connect to the display
            if self[:connected]
                logger.debug "-- Polling Display"
                do_poll
            end
        end

        on_update
    end

    def on_update
        @id = (setting(:display_id) || 1).to_s.rjust(2, '0')
    end


    Command = {
        power: 'a',
        input: 'b',
        screen_mute: 'd',
        volume_mute: 'e',
        volume: 'f',
        contrast: 'g',
        brightness: 'h',
        sharpness: 'k'
    }
    Lookup = Command.invert


    def power(state, broadcast = nil)
        val = 0
        if is_affirmative?(state)
            val = 1
            wake(broadcast)
        end

        do_send(Command[:power], val, name: :power)
    end


    # NOTE:: We are currently only supporting the PC values here
    Inputs = {
        dvi: 112,
        hdmi: 160,
        hdmi2: 161,
        display_port: 208 
    }
    Inputs.merge!(Inputs.invert)
    def input(source)
        val = Inputs[source.to_sym]
        do_send(Command[:input], val, 'x'.freeze, name: :input)
    end

    # Audio mute
    def mute_audio(state = true)
        val = is_affirmative?(state) ? 0 : 1
        do_send(Command[:volume_mute], val, name: :volume_mute)
    end
    alias_method :mute, :mute_audio

    def unmute_audio
        mute_audio(false)
    end
    alias_method :unmute, :unmute_audio

    # Display Mute
    def mute_display(state = true)
        val = is_affirmative?(state) ? 1 : 0
        do_send(Command[:screen_mute], val, name: :screen_mute)
    end

    def unmute_display
        mute_display(false)
    end


    # Status values we are interested in polling
    def do_poll
        input?
        screen_mute?
        volume_mute?
        volume?
    end


    # Automatically creates a callable function for each command
    #    http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
    #    http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
    #

    # Status requests
    Command.each do |key, cmd|
        define_method :"#{key}?" do |**options, &block|
            options[:priority] ||= 0
            options[:name] = :"#{key}_status"
            options[:emit] ||= block
            do_send cmd, 0xFF, **options
        end
    end

    def input?(**options, &block)
        options[:priority] ||= 0
        options[:name] = :input_status
        options[:emit] ||= block
        do_send Command[:input], 0xFF, 'x'.freeze, **options
    end

    # These commands all support values between 0 and 100
    [:volume, :contrast, :brightness, :sharpness].each do |cmd|
        define_method cmd do |value, **options|
            val = in_range value.to_i, 0x64 # 0 - 100
            options[:name] = cmd
            do_send Command[cmd], val, **options
        end
    end

    def wake(broadcast = nil)
        mac = setting(:mac_address)
        if mac
            # config is the database model representing this device
            wake_device(mac, broadcast)
        end
    end


    protected


    def do_send(cmd, data, system = :k, **options)
        cmd = "#{system}#{cmd} #{@id} #{data.to_s(16).upcase.rjust(2, '0')}\r"
        send cmd, options
    end

    def received(data, resolve, command)
        logger.debug { "LG sent #{data}" }

        # Deals with multi-line responses
        cmd, set, resp = data.split(' ')
        resp_value = 0
        if resp[0..1] == 'OK'
            # Extract the response value
            resp_value = resp[2..-1].to_i(16)
        else
            # Request failed. We don't want to retry
            return :abort
        end

        case Lookup[cmd]
        when :power
            self[:power] = resp_value == 1
        when :input
            self[:input] = Inputs[resp_value] || :unknown
        when :screen_mute
            self[:display_mute] = resp_value == 1
        when :volume_mute
            self[:audio_mute] = resp_value == 1
        when :contrast
            self[:contrast] = resp_value
        when :brightness
            self[:brightness] = resp_value
        when :sharpness
            self[:sharpness] = resp_value
        when :volume
            self[:volume] = resp_value
        else
            return :ignore
        end

        :success
    end


end

