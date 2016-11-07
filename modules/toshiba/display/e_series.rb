module Toshiba; end
module Toshiba::Display; end


class Toshiba::Display::ESeries
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    implements :device
    descriptive_name 'Toshiba E-Series LCD Monitor'
    generic_name :Display

    # Communication settings
    delay between_sends: 100


    def on_load
        on_update
    end

    def on_update
        @buffer ||= ''
        defaults({
            max_waits: 5
        })

        @force_state = setting(:force_state)
        self[:power_target] = setting(:power_target) if @force_state
    end

    def connected
        @buffer = String.new

        @polling_timer = schedule.every('30s') do
            logger.debug "-- Polling Display"
            do_poll
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


    def power(state)
        promise = if is_affirmative?(state)
            self[:power_target] = self[:power] = true
            do_send([0x19, 0xD3, 0x02, 0x00, 0x00, 0x60, 0x02, 0x00], name: :power)
        else
            self[:power_target] = self[:power] = false
            do_send([0x19, 0xD3, 0x02, 0x00, 0x00, 0x60, 0x01, 0x00], name: :power)
        end

        define_setting(:power_target, self[:power_target]) if @force_state
        promise
    end

    def power?(options = {}, &block)
        options[:emit] = block if block_given?
        options[:name] = :power_query
        do_send([0x19, 0xD8, 0x03, 0x00, 0x00, 0x60, 0x07, 0x00], options)
    end

    INPUTS = {
        hdmi: [0x0E, 0xD2, 0x01, 0x00, 0x00, 0x20, 0x03, 0x00],
        vga:  [0x6E, 0xD2, 0x01, 0x00, 0x00, 0x20, 0x01, 0x00]
    }
    def switch_to(input, **options)
        options[:name] = :switch
        inp = input.to_sym
        cmd = INPUTS[inp]

        result = if cmd
            do_send INPUTS[inp], options
            self[:input] = inp
        else
            logger.warn { "Input requested is not available #{input}" }
            false  # TODO:: should be a promise rejection
        end

        result
    end

    # Audio mute
    def mute_audio(state = true)
        muted = is_affirmative?(state)
        result = if muted
            do_send([0xD6, 0xD2, 0x01, 0x00, 0x02, 0x20, 0x01, 0x00], name: :audio_mute)
        else
            do_send([0x46, 0xD3, 0x01, 0x00, 0x02, 0x20, 0x00, 0x00], name: :audio_mute)
        end

        self[:audio_mute] = muted

        result
    end
    alias_method :mute, :mute_audio

    def unmute_audio
        mute_audio(false)
    end
    alias_method :unmute, :unmute_audio

    # Display Mute
    def mute_display(state = true)
        muted = is_affirmative?(state)
        result = if muted
            do_send([0x19, 0xD3, 0x02, 0x00, 0x00, 0x60, 0x02, 0x00], name: :display_mute)
        else
            do_send([0x19, 0xD3, 0x02, 0x00, 0x00, 0x60, 0x01, 0x00], name: :display_mute)
        end

        self[:display_mute] = muted

        result
    end

    def unmute_display
        mute_display(false)
    end


    def volume(value, **options)
        options[:name] = :volume

        value = in_range(value.to_i, 0x1D, 0)
        promise = do_send([0x31, 0xD3, 0x03, 0x00, 0x01, 0x20, 0x01, value], options)

        self[:volume] = value

        promise
    end


    def do_poll
        power? do
            if self[:power]
                audio_mute?
                volume?
                input?
            end

            if @force_state && !self[:power_target].nil? && self[:power] != self[:power_target]
                power(self[:power_target])
            end
        end
    end


    def input?
        do_send([0xCD, 0xD2, 0x02, 0x00, 0x00, 0x20, 0x00, 0x00], {
            name: :input_query,
            priority: 0
        })
    end

    def screen_mute?
        do_send([0x19, 0xD8, 0x03, 0x00, 0x00, 0x60, 0x07, 0x00], {
            name: :screen_query,
            priority: 0
        })
    end

    def audio_mute?
        do_send([0x75, 0xD3, 0x02, 0x00, 0x02, 0x20, 0x00, 0x00], {
            name: :audio_query,
            priority: 0
        })
    end

    def volume?
        do_send([0x31, 0xD3, 0x02, 0x00, 0x01, 0x20, 0x00, 0x00], {
            name: :vol_query,
            priority: 0
        })
    end


    protected


    def received(data, resolve, command)
        # Buffer data if required
        if command && (@buffer.length > 0 || data[0] == "\x1D")
            @buffer << data
            
            if @buffer.length >= 3
                data = @buffer[0..2]
                @buffer = String.new(@buffer[3..-1])
            else
                return :ignore
            end
        end

        logger.debug {
            cmd = String.new "Toshiba sent 0x#{byte_to_hex(data)}"
            cmd << " for command #{command[:name]}" if command
            cmd
        }

        # 06 == Success, 15 == No Action
        if data[0] == "\x06" || data[0] == "\x15"
            return :success
        elsif data.length == 1
            # We have an unknown response code
            return :abort 
        end

        if command
            case command[:name]
            when :vol_query
                self[:volume] = data[2].ord
            when :audio_query
                self[:audio_mute] = data == "\x1D\0\1"
            when :screen_query
                self[:display_mute] = data == "\x1D\0\1"
            when :input_query
                self[:input] = case data[2].ord
                when 2
                    :vga
                when 3
                    :hdmi
                else
                    :unknown
                end
            when :power_query
                self[:power] = data != "\x1D\0\0"
            end
        end

        :success
    end


    PREFIX = [0xBE, 0xEF, 0x03, 0x06, 0x00]
    def do_send(cmd, options = {})
        data = PREFIX + cmd
        logger.debug { "sending to Toshiba: 0x#{byte_to_hex(data)}" }
        send data, options
    end
end
