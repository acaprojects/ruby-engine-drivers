module Bss; end

# TCP port 1023

class Bss::Blu100
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    
    def on_load
        defaults({
            :wait => false
        })
        config({
            tokenize: true,
            delimiter: "\x03",
            indicator: "\x02"
        })

        @type_lookup = {}

        on_update
    end
    
    def on_unload
    end
    
    def on_update
    end

    def connected
        subscribe_percent(1, 60000)
        @polling_timer = schedule.every('150s') do  # Every 2.5 min
            subscribe_percent(1, 60000)             # Request the level of Hybrid I/O Card A
        end                                         # This works to maintain the connection
    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #   Hence the check if timer is nil here
        #
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end


    OPERATION_CODE = {
        :set_state => 0x88,
        :subscribe_state => 0x89,
        :unsubscribe_state => 0x8A,
        :venue_preset => 0x8B,
        :param_preset => 0x8C,
        :set_percent => 0x8D,
        :subscribe_percent => 0x8E,
        :unsubscribe_percent => 0x8F,
        :set_relative_percent => 0x90
    }
    OPERATION_CODE.merge!(OPERATION_CODE.invert)


    def preset(number)
        number = number.to_i

        do_send([OPERATION_CODE[:venue_preset]] + number_to_data(number))
    end
    

    #
    # Level controls
    #
    def fader(fader_ids, percent, index = 0)
        faders = fader_ids.is_a?(Array) ? fader_ids : [fader_ids]
        faders.each do |fader|
            index_data = id_to_array(index, :gain)

            percent = percent.to_i
            percent = 6553600 if percent > 6553600
            percent = 0 if percent < 0

            percent = number_to_data(percent)

            do_send([OPERATION_CODE[:set_percent]] + NODE + VIRTUAL + number_to_object(fader.to_i) + index_data + percent)
            subscribe_percent(fader)
        end
    end
    # Named params version
    def faders(ids:, level:, index: 0)
        fader(ids, level, index)
    end

    def mute(fader_ids, val = true, index = 1)
        faders = fader_ids.is_a?(Array) ? fader_ids : [fader_ids]
        faders.each do |fader|
            actual = val ? 1 : 0

            index_data = id_to_array(index, :mute)

            do_send([OPERATION_CODE[:set_state]] + NODE + VIRTUAL + number_to_object(fader.to_i) + index_data + number_to_data(actual))
            subscribe_state(fader)
        end
    end
    # Named params version
    def mutes(ids:, muted: true, index: 1)
        mute(ids, muted, index)
    end

    def unmute(fader, index = 1)
        mute(fader, false, index)
    end


    def query_fader(fader_ids, index = 0)
        faders = fader_ids.is_a?(Array) ? fader_ids : [fader_ids]
        faders.each do |fader|
            subscribe_percent(fader, index)
        end
    end
    # Named params version
    def query_faders(ids:, index: 0)
        query_fader(ids, index)
    end

    def query_mute(fader_ids, index = 1)
        faders = fader_ids.is_a?(Array) ? fader_ids : [fader_ids]
        faders.each do |fader|
            subscribe_state(fader, index)
        end
    end
    # Named params version
    def query_mutes(ids:, index: 1)
        query_mute(ids, index)
    end


    #
    # Percent controls for relative values
    #
    def subscribe_percent(fader, index = 0, rate = 0)   # rate must be 0 for non meter controls
        index_data = id_to_array(index, :gain)

        fader = number_to_object(fader.to_i)
        rate = number_to_data(rate.to_i)

        do_send([OPERATION_CODE[:subscribe_percent]] + NODE + VIRTUAL + fader + index_data + rate)
    end

    def unsubscribe_percent(fader, index = 0)   # rate must be 0 for non meter controls
        index_data = id_to_array(index, :gain)

        fader = number_to_object(fader.to_i)
        rate = number_to_data(0)

        do_send([OPERATION_CODE[:unsubscribe_percent]] + NODE + VIRTUAL + fader + index_data + rate)
    end

    #
    # State controls are for discrete values
    #
    def subscribe_state(fader, index = 1, rate = 0) # 1000 == every second
        index_data = id_to_array(index, :mute)

        fader = number_to_object(fader.to_i)
        rate = number_to_data(rate.to_i)

        do_send([OPERATION_CODE[:subscribe_state]] + NODE + VIRTUAL + fader + index_data + rate)
    end

    def unsubscribe_state(fader, index = 1) # 1000 == every second
        index_data = id_to_array(index, :mute)

        fader = number_to_object(fader.to_i)
        rate = number_to_data(0)

        do_send([OPERATION_CODE[:unsubscribe_state]] + NODE + VIRTUAL + fader + index_data + rate)
    end


    def received(data, resolve, command)
        #
        # Grab the message body
        #
        data = data.split("\x02")
        data = str_to_array(data[-1])

        #
        # Unescape any control characters
        #
        message = []
        found = false
        data.each do |byte|
            if found
                found = false
                message << (byte - 0x80)
            elsif RESERVED_CHARS.include? byte
                found = true
            else
                message << byte
            end
        end

        #
        # Process the response
        #
        if check_checksum(message)
            logger.debug "Blu100 sent 0x#{byte_to_hex(array_to_str(message))}"

            data = byte_to_hex(array_to_str(message[-4..-1])).to_i(16)
            type = message[0]       # Always sent

            node = message[1..2]
            vi = message[3]
            obj = message[4..6]
            cntrl = message[7..8]

            case OPERATION_CODE[type]
            when :set_state   # This is the mute response
                obj = byte_to_hex(array_to_str(obj)).to_i(16)
                index = byte_to_hex(array_to_str(cntrl)).to_i(16)
                if @type_lookup[cntrl] == :mute
                    self[:"fader#{obj}_#{index}_mute"] = data == 1
                else
                    self[:"fader#{obj}_#{index}"] = data
                end
            when :subscribe_state
            when :unsubscribe_state
            when :venue_preset
            when :param_preset
            when :set_percent   # This is the fader response
                obj = byte_to_hex(array_to_str(obj)).to_i(16)
                index = byte_to_hex(array_to_str(cntrl)).to_i(16)
                self[:"fader#{obj}_#{index}"] = data
            when :subscribe_percent
            when :unsubscribe_percent
            when :set_relative_percent
            end

            return :success
        else
            logger.warn "Blu100 Checksum error: 0x#{byte_to_hex(array_to_str(message))}"
            return :failed
        end
    end


    protected


    def id_to_array(id, type)
        data = str_to_array(hex_to_byte(id.to_s(16).rjust(4, '0')))
        @type_lookup[data] = type
        data
    end

    def number_to_data(num)
        str_to_array(hex_to_byte(num.to_s(16).rjust(8, '0')))
    end

    def number_to_object(num)
        str_to_array(hex_to_byte(num.to_s(16).rjust(6, '0')))
    end


    RESERVED_CHARS = [0x02, 0x03, 0x06, 0x15, 0x1B]
    NODE = [0,0]    # node we are connected to
    VIRTUAL = [3]   # virtual device is always 3 for audio devices


    def check_checksum(data)
        #
        # Loop through the second to the second last element
        #   Delimiter is removed automatically
        #
        check = 0
        data[0..-2].each do |byte|
            check = check ^ byte
        end
        return check == data.pop    # Check the check sum equals the last element
    end

    

    def do_send(command, options = {})
        #
        # build checksum
        #
        check = 0
        command.each do |byte|
            check = check ^ byte
        end
        command = command + [check]

        #
        # Substitute reserved characters
        #
        substituted = []
        command.each do |byte|
            if RESERVED_CHARS.include? byte
                substituted << 0x1B << (byte + 0x80)
            else
                substituted << byte
            end
        end

        #
        # Add the control characters
        #
        substituted.unshift 0x02
        substituted << 0x03

        send(substituted, options)
    end
end
