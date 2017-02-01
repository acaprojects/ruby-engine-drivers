module Philips; end
module Philips::Display; end


class Philips::Display::SicpProtocol
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 5000
    descriptive_name 'Philips SICP Display'
    generic_name :Display

    # Communication settings
    delay between_sends: 100


    def on_load
        on_update
    end

    def on_update
        @buffer ||= []
        self[:volume_min] = 0
        self[:volume_max] = setting(:volume_max) || 0xFE
        self[:monitor_id] = setting(:monitor_id) || 1
        self[:group_id] = setting(:group_id) || 0

        # Mute the display audio
        @audio_out_only = setting(:audio_out_only) || false

        # Audio out to be a constant level
        @audio_out_constant = setting(:audio_out_level)
    end

    def connected
        @buffer.clear

        @polling_timer = schedule.every('50s') do
            logger.debug "-- Polling Display"
            do_poll
        end
    end

    def disconnected
        @buffer.clear

        #
        # Disconnected may be called without calling connected
        #    Hence the check if timer is nil here
        #
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end


    Command = {
        power: 0x18,
        power_recovery: 0xA3,
        input: 0xAC,
        volume: 0x44
    }

    QueryCodes = {
        power: 0x19,
        power_recovery: 0xA4,
        input: 0xAD,
        volume: 0x45
    }
    QueryCodeLookup = QueryCodes.invert
    QueryCodeLookup.merge!({
        0x06 => :success,
        0x15 => :bad_request,

        # checksum error and a won't perform op in my current state feedback
        0x18 => :error
    })

    # Generate the query functions
    QueryCodes.each do |cmd, code|
        define_method :"#{cmd}?" do | **options|
            options[:priority] ||= 0
            if block_given?
                options[:emit] = proc {
                    yield
                }
            end
            do_send code, **options
        end
    end


    def power(state)
        value = if is_affirmative?(state)
            self[:power] = true
            0x02
        else
            self[:power] = false
            0x01
        end
        do_send Command[:power], value, name: :power
    end


    RecoveryMode = {
        power_off: 0x00,
        power_on: 0x01,
        last_known_state: 0x02
    }
    RecoveryMode.merge!(RecoveryMode.invert)

    def set_power_recovery(mode)
        do_send Command[:power_recovery], RecoveryMode[mode.to_sym], name: :power_mode
    end


    Inputs = {
        video: 0x01,
        svideo: 0x02,
        component: 0x03,
        vga: 0x05,
        hdmi2: 0x06,
        display_port2: 0x07,
        usb2: 0x08,
        display_port: 0x0A,
        usb: 0x0C,
        hdmi: 0x0D,
        dvi: 0x0E,
        hdmi3: 0x0F,
        browser: 0x10,
        digital_media_server: 0x12
    }
    Inputs.merge!(Inputs.invert)

    def switch_to(input)
        inp = self[:input] = input.to_sym
        do_send Command[:input], Inputs[inp], 0, 1, 0, name: :input
    end

    # Audio mute
    def mute_audio(state = true)
        if is_affirmative?(state)
            @vol_main = self[:volume] || 20
            @vol_aout = self[:audio_out] || @vol_main
            volume(0, force_level: true)
        else
            volume(@before_mute || self[:volume], @vol_aout, force_level: true)
        end
    end
    alias_method :mute, :mute_audio

    def unmute_audio
        mute_audio(false)
    end
    alias_method :unmute, :unmute_audio

    # Display Mute
    def mute_display(state = true)
        power(!state)
    end

    def unmute_display
        mute_display(false)
    end


    def volume(value, audio_out = nil, force_level: false)
        if @audio_out_constant && !force_level
            audio_out = @audio_out_constant
        else
            audio_out ||= value
        end

        if @audio_out_only
            value = 0
            self[:volume] = audio_out
        else
            self[:volume] = value
        end

        do_send Command[:volume], value, audio_out, name: :volume
    end


    def do_poll
        power? do
            if self[:power]
                volume?
                input?
            end
        end
    end


    protected


    def process(message, command)
        logger.debug { "processing #{QueryCodeLookup[message[3]]} cmd"  }
        case QueryCodeLookup[message[3]]
        when :power
            self[:power] = message[4] == 0x02
        when :input
            self[:input] = Inputs[message[4]]
        when :volume
            if @audio_out_only
                self[:volume] = message[5]
            else
                self[:volume] = message[4]
                self[:audio_out] = message[5]
            end
        when :bad_request
            logger.warn {
                err = String.new "bad request warning"
                err << " for cmd 0x#{command[:data].bytes[3].to_s(16)}" if command
            }
        when :error
            logger.error {
                err = String.new "error response received"
                err << " for cmd 0x#{command[:data].bytes[3].to_s(16)}" if command
            }
        end

        :success
    end

    def received(data, resolve, command)
        logger.debug { "received: 0x#{byte_to_hex(data)}" }

        # Buffer data
        @buffer.concat str_to_array(data)

        # Extract any messages
        tokens = []
        while @buffer[0] && @buffer.length >= @buffer[0]
            tokens << @buffer.slice!(0, @buffer[0])
        end

        # Process responses
        if tokens.length > 0
            response = nil
            tokens.each do |message|
                response = process(message, command)
            end
            response
        else
            :ignore
        end
    end

    def checksum(data)
        sum = data[0]
        data[1..-1].each do |byte|
            sum = sum ^ byte
        end
        sum & 0xFF
    end

    def do_send(*cmd, **options)
        data = [cmd.length + 4, self[:monitor_id], self[:group_id]] + cmd
        data << checksum(data)

        logger.debug { "sending: 0x#{byte_to_hex(data)}" }
        send data, options
    end
end
