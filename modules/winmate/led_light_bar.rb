module Winmate; end


class Winmate::LedLightBar
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    implements :device
    descriptive_name 'Winmate PC - LED Light Bar'
    generic_name :StatusLight

    # Communication settings
    delay between_sends: 100


    def on_load
    end

    def on_unload
    end

    def on_update
    end


    def connected
        @buffer = String.new

        do_poll
        @polling_timer = schedule.every('50s') do
            logger.debug "-- Polling Winmate LED"
            do_poll
        end
    end

    def disconnected
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end


    Colours ||= {
        red: 0x10,
        green: 0x11,
        blue: 0x12
    }
    Colours.merge!(Colours.invert)

    Commands ||= {
        set: 0x61,
        get: 0x60
    }


    def query(led, options = {})
        do_send(options.merge({
            command: :get,
            colour: led.to_sym
        }))
    end

    # Note:: value is between 0 and 255
    def set(led, value, options = {})
        do_send(options.merge({
            command: :set,
            colour: led.to_sym,
            value: (value.to_i & 0xFF)
        }))
    end


    def received(data, resolve, command)
        logger.debug { "received #{byte_to_hex(data)}" }

        # Buffer data if required
        if @buffer.length > 0
            @buffer << data
            data = @buffer
        end

        len = data.getbyte(0)
        if len <= data.length && check_checksum(len, data)
            @buffer = data[len..-1]
            process_response(data[1...len])
        elsif len > data.length
            # buffer the data as it hasn't all arrived yet
            @buffer = data
            :ignore
        else
            logger.warn "Error processing response. Possibly incorrect baud rate configured"
            @buffer = String.new
            :abort
        end
    end


    private


    # 2’s complement
    def build_checksum(data)
        sum = 0
        data.each do |byte|
            sum += byte
        end
        ((~(sum & 0xFF)) + 1) & 0xFF
    end

    # Seems the device is a bit off?
    def confirm_checksum(data)
        sum = 0
        data.each do |byte|
            sum += byte
        end
        (~(sum & 0xFF)) & 0xFF
    end

    def check_checksum(length, data)
        check = str_to_array(data[0...length])
        result = check.pop
        result == confirm_checksum(check)
    end

    def process_response(resp)
        data = str_to_array(resp)
        indicator = data[0]

        colour = Colours[indicator]
        case colour
        when :red, :green, :blue
            self[colour] = data[1]
        else
            char = (String.new << indicator)
            if char == 'C'
                :success
            else
                :abort
            end
        end
    end


    def do_poll
        query(:red, priority: 0)
        query(:green, priority: 0)
        query(:blue, priority: 0)
    end


    def do_send(command:, colour:, value: nil, **options)
        cmd = Commands[command]
        led = Colours[colour]

        # Build core request
        req = [cmd, led]
        req << value if value

        # Add length indicator
        len = req.length + 2
        req.unshift len

        # Calculate checksum
        req << build_checksum(req)

        logger.debug { "requesting #{byte_to_hex(req)}" }

        options[:name] = "#{command}_#{colour}"
        send(req, options)
    end
end
