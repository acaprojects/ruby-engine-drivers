module Lg; end
module Lg::Lcd; end


# There is a secret menu that allows you to disable power management
# 1. Press and hold the 'Setting' button on the remote for 7 seconds
# 2. Press: 0 0 0 0 OK (Press Zero four times and then OK)
# 3. From the signage setup, turn off DPM
#    * Alternatively set DPM to 1m and PM to Screen Off Always

# For firmware updates there is a good guide here:
# https://support.signagelive.com/hc/en-us/articles/204116196-LG-WebOS-Checking-and-Updating-Firmware-Version


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

        self[:power_stable] = true
        self[:input_stable] = true
    end

    def on_update
        @id_num = setting(:display_id) || 1
        @id = @id_num.to_s.rjust(2, '0')
    end

    def connected
        #configure_dpm
        wake_on_lan(true)
        no_signal_off(false)
        auto_off(false)
        do_poll
    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #
        self[:power] = false  # As we may need to use wake on lan
        self[:power_stable] = false if !self[:power_target].nil? && self[:power_target] != self[:power]
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
        wol: 'w',
        no_signal_off: 'g',
        auto_off: 'n',
        dpm: 'j'
    }
    Lookup = Command.invert


    def power(state, broadcast = @last_broadcast)
        power_on = is_affirmative?(state)

        # This allows polling 
        @last_broadcast = broadcast if broadcast
        self[:power_target] = power_on
        self[:power_stable] = false

        if self[:connected]
            mute_display !power_on
        end
        wake(broadcast) if power_on
    end

    def hard_off
        self[:power_target] = false
        self[:power_stable] = true
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
        self[:input_stable] = false

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

            if @id_num == 1
                input?
                volume_mute?
                volume?
            end
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


    # DPM is "display power management"
    # turn it to 1 min
    def configure_dpm(time_out = 4)
        # 0 == off
        # 1 == 5s
        # 2 == 10s
        # 3 == 15s
        # 4 == 1m
        # 5 == 3m
        # 6 == 5m
        # 7 == 10m
        do_send(Command[:dpm], 4, :f, name: :disable_dpm)

        # The action DPM takes needs to be configured using a remote
        # The action should be set to: screen off always
    end
    
    def no_signal_off(enable = false)
        val = is_affirmative?(enable) ? 1 : 0
        do_send(Command[:no_signal_off], val, :f, name: :disable_no_sig_off)
    end

    def auto_off(enable = false)
        val = is_affirmative?(enable) ? 1 : 0
        do_send(Command[:auto_off], val, :m, name: :disable_auto_off)
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
            if self[:input_target] == self[:input]
                self[:input_stable] = true
            else
                switch_to(self[:input_target])
            end
        when :screen_mute
            # This indicates power status as hard off we are disconnected
            self[:power] = resp_value != 1

            if self[:power_stable] == false
                # Power target should only be auto-set to on. Off is undesirable.
                self[:power_target] = On if self[:power_target].nil? && self[:power]

                # The target has been achieved
                # This does allow users to turn off displays with a remote if they desire
                if self[:power_target] == self[:power]
                    self[:power_stable] = true
                elsif self[:power_target] != nil
                    power(self[:power_target])
                end
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
        when :dpm
            logger.debug { "DPM changed!" }
        when :no_signal_off
            logger.debug { "No Signal Auto Off changed!" }
        when :auto_off
            logger.debug { "Auto Off changed!" }
        else
            return :ignore
        end

        :success
    end


end

