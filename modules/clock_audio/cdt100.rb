module ClockAudio; end

class ClockAudio::Cdt100
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    udp_port 50000
    descriptive_name 'Clock Audio CDT100 Microphones'
    generic_name :Microphone


    # Communication settings
    tokenise delimiter: "\r\0"
    wait_response false # NOTE:: Temporary!!


    def on_load
    end

    def on_update
    end
    
    def connected
        # Have to init comms
        #do_poll
    end


    Commands = {
        phantom: 'PP',
        query: 'QUERY',
        set_ch32: 'SCH32',
        get_ch32: 'GCH32',
        set_arm_c: 'SARMC',
        get_arm_c: 'GARMC',
        version: 'VERSION',
        async: 'SASIP',
        input_status: 'BSTATUS',
        led_red: 'R=',
        led_green: 'G=',
        input: 'SC=',
        id: 'ID=',
        address: 'GAS',
        preset_save: 'SAVE',
        preset_load: 'LOAD'
    }
    Commands.merge!(Commands.invert)
    MaxChannels = 4


    def get_version(**options)
        do_send(Commands[:version], **options)
    end

    def set_phantom(index, state, **options)
        val = is_affirmative?(state) ? '1' : '0'
        if index > 0
            do_send(Commands[:phantom], index, val, **options)
        else
            1.upto(MaxChannels) do |chan|
                do_send(Commands[:phantom], chan, val, **options)
            end
        end
    end

    def set_red_led(index, state, **options)
        val = is_affirmative?(state) ? 'R=1' : 'R=0'
        if index > 0
            do_send(Commands[:set_ch32], index, val, **options)
        else
            1.upto(MaxChannels) do |chan|
                do_send(Commands[:set_ch32], chan, val, **options)
            end
        end
    end

    def set_green_led(index, state, **options)
        val = is_affirmative?(state) ? 'G=1' : 'G=0'
        if index > 0
            do_send(Commands[:set_ch32], index, val, **options)
        else
            1.upto(MaxChannels) do |chan|
                do_send(Commands[:set_ch32], chan, val, **options)
            end
        end
    end

    def set_arm_c(state, **options)
        val = is_affirmative?(state) ? '1' : '0'
        do_send(Commands[:set_arm_c], val, **options)
    end


    # Only seems to be a single preset??
    def save_preset(number = 0, **options)
        # Number is ignored for now
        do_send(Commands[:preset_save], 0, **options)
    end

    # Only seems to be a single preset??
    def load_preset(number = 0, **options)
        # Number is ignored for now
        do_send(Commands[:preset_load], 0, **options)
    end

    # TODO:: This isn't implemented yet!
    def start_async
        do_send(Commands[:async], "#{local_address}:#{local_port}", **options)
    end

  
    def received(data, resolve, command)        # Data is default received as a string
        logger.debug { "sent: #{data}" }

        result = data.split(' ')

        if result[0] == 'ACK'
            case Commands[result[1]]
            when :set_ch32
                # ACK SCH32 1 G=1
                channel = result[2]

                # G= or R=
                led = result[3][0..1]

                # 1 == ON, 0 == OFF
                state = result[3][2..-1].to_i == 1

                # led_red_2 = On
                set_status(led, channel, state)

            when :get_ch32
                # ACK GCH32 CH G=1 1 R=2 1

                # Remove garbage
                result = result[(result.index('CH') + 1)..-1]

                begin
                    item, state = result.shift.split('=')
                    channel = result.shift

                    set_status("#{item}=", channel, state.to_i == 1)
                end while result.length > 1

            when :query
                # ACK QUERY garbage PP 1 ON PP 3 OFF
                while result[0] != 'PP'
                    result.shift
                end

                while result[0] == 'PP'
                    item = result.shift # PP
                    channel = result.shift
                    state = result.shift == 'ON'

                    set_status(item, channel, state)
                end

            when :phantom
                # ACK PP 2 1
                item = result[1] # PP
                channel = result[2]
                state = result[3].to_i == 1

                set_status(item, channel, state)

            when :set_arm_c, :get_arm_c
                # ACK GARMC 1
                self[:arm_c] = result[2].to_i == 1

            when :address
                # ACK GAS something,with,commas
                self[:address] = result[2]

            when :preset_load
                # Need to run query command here

            end
        elsif result[0] == 'NACK'
            logger.warn {
                msg = "Command failed with response #{data}"
                msg << " for cmd: #{command[:data]}" if command
                msg
            }
            return :abort
        else
            # We shouldn't really make it here
        end

        :success
    end


    protected


    def set_status(item, channel, state)
        if channel == 0
            1.upto(MaxChannels) do |index|
                self["#{Commands[item]}_#{index}"] = state
            end
        else
            self["#{Commands[item]}_#{channel}"] = state
        end
    end

    def do_send(cmd, *args, **options)
        if args.length > 0
            send("#{cmd} #{args.join(' ')}\r", options)
        else
            send("#{cmd}\r", options)
        end
    end
end

