module Lg; end
module Lg::Lcd; end


# This device does not hold the connection open. Must be configured as makebreak
class Lg::Lcd::ModelLs5
    include ::Orchestrator::Constants    # these provide optional helper methods
    include ::Orchestrator::Transcoder   # (not used in this module)


    # Discovery Information
    tcp_port 9761
    descriptive_name 'LG WebOS LCD Monitor'
    generic_name :Display

    # Communication settings
    tokenize delimiter: 'x'
    delay between_sends: 150, on_receive: 200
    makebreak!


    def on_load
        on_update
        @last_broadcast = nil

        schedule.every('50s') do
            logger.debug "-- Polling Display"
            do_poll
        end
    end

    def on_update
        @id = (setting(:display_id) || 1).to_s.rjust(2, '0')
    end

    def connected
        dpm(false)
        wake_on_lan(true)
        do_poll
    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #
        self[:power] = false  # As we may need to use wake on lan
    end


    Command = {
        power: 'a',
        input: 'b',
        screen_mute: 'd',
        volume_mute: 'e',
        volume: 'f',
        contrast: 'g',
        brightness: 'h',
        sharpness: 'k',
        wol: 'w'
    }
    Lookup = Command.invert


    def power(state, broadcast = @last_broadcast)
        power_on = is_affirmative?(state)

        # This allows polling 
        @last_broadcast = broadcast if broadcast

        if self[:connected]
            self[:power_target] = power_on
            mute_display !power_on
        end
        wake(broadcast) if power_on
    end

    def hard_off
        self[:power_target] = false
        do_send(Command[:power], 0, name: :power, priority: 99)
    end


    # NOTE:: We are currently only supporting the PC values here
    Inputs = {
        dvi: 112,
        hdmi: 160,
        hdmi2: 161,
        display_port: 208 
    }
    Inputs.merge!(Inputs.invert)
    def switch_to(source)
        logger.debug "Requesting input: #{source}"

        # Input target allows us to ensure the correct input is selected
        # After a WOL event
        source_sym = source.to_sym
        self[:input_target] = source_sym

        val = Inputs[source_sym]
        do_send(Command[:input], val, 'x'.freeze, name: :input, delay_on_receive: 2000)
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
        options = {
            name: :screen_mute
        }
        options[:delay_on_receive] = 5000 if self[:power] == state
        val = is_affirmative?(state) ? 1 : 0
        do_send(Command[:screen_mute], val, **options)

        # Check power target after a power change
        if self[:power] == state
            self[:power] = !state
            screen_mute?
        end
    end

    def unmute_display
        mute_display(false)
    end


    # Status values we are interested in polling
    def do_poll
        if self[:connected]
            screen_mute?
            input?
            volume_mute?
            volume?
        elsif self[:power_target] == On
            power On
        end
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


    # DPM is "display power management" turn it off to ensure the display does not auto sleep
    def dpm(enable = false)
        val = is_affirmative?(enable) ? 1 : 0
        do_send(Command[:dpm], val, :f, name: :disable_dpm)
    end
    
    def wake_on_lan(enable = true)
        val = is_affirmative?(enable) ? 1 : 0
        do_send(Command[:wol], val, :f, name: :enable_wol)
    end

    def wake(broadcast = nil)
        mac = setting(:mac_address)
        if mac
            # config is the database model representing this device
            wake_device(mac, broadcast)
            logger.debug { 
                info = "Wake on Lan for MAC #{mac}"
                info << " directed to VLAN #{broadcast}" if broadcast
                info
            }
        else
            logger.debug { "No MAC address provided" }
        end
    end


    protected


    def do_send(cmd, data, system = :k, **options)
        logger.debug { "Sending command #{options[:name]} - #{system}#{cmd} #{@id} #{data.to_s(16).upcase.rjust(2, '0')}" }
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
            self[:input_target] = self[:input] if self[:input_target].nil?
            if self[:input_target] != self[:input]
                switch_to(self[:input_target])
            end
        when :screen_mute
            # This indicates power status as hard off we are disconnected
            self[:power] = resp_value != 1
            self[:power_target] = self[:power] if self[:power_target].nil?
            if self[:power_target] != self[:power]
                power(self[:power_target])
            end
        when :volume_mute
            self[:audio_mute] = resp_value == 0
        when :contrast
            self[:contrast] = resp_value
        when :brightness
            self[:brightness] = resp_value
        when :sharpness
            self[:sharpness] = resp_value
        when :volume
            self[:volume] = resp_value
        when :wol
            logger.debug { "WOL Enabled!" }
        else
            return :ignore
        end

        :success
    end


end

