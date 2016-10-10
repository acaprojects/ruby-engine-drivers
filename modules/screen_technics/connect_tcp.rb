module ScreenTechnics; end


# Default user: Admin
# Default pass: Connect


class ScreenTechnics::ConnectTcp
    include ::Orchestrator::Constants


    # Discovery Information
    descriptive_name 'Screen Technics Projector Screen Control (Raw TCP)'
    generic_name :Screen

    # Communication settings
    delay between_sends: 120, on_receive: 120
    tcp_port 3001
    tokenize delimiter: "\r\n"
    clear_queue_on_disconnect!


    Commands = {
        up: 30,
        down: 33,
        status: 1,
        stop: 36
    }
    Commands.merge!(Commands.invert)


    def on_load
        on_update
    end
    
    def on_update
        @count = setting(:screen_count) || 1
    end
    
    def connected
        (1..@count).each { |index| query_state(index) }
        @polling_timer = schedule.every('15s') {
            (1..@count).each { |index| query_state(index) }
        }
    end

    def disconnected
        # Disconnected will be called before connect if initial connect fails
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end
    
    def state(new_state, index = 1)
        if is_affirmative?(new_state)
            down(index)
        else
            up(index)
        end
    end

    def down(index = 1)
        stop(index)
        down_only(index)
        query_state(index)
    end

    def down_only(index = 1)
        index = relative_address(index)
        send "#{Commands[:down]} #{index}\r\n", name: :direction
    end

    def up(index = 1)
        stop(index)
        up_only(index)
        query_state(index)
    end

    def up_only(index = 1)
        index = relative_address(index)
        send "#{Commands[:up]} #{index}\r\n", name: :direction
    end

    def stop(index = 1, emergency = false)
        actual = relative_address(index)
        if emergency
            send "#{Commands[:stop]} #{actual}\r\n", name: :stop, priority: 99, clear_queue: true
        else
            send "#{Commands[:stop]} #{actual}\r\n", name: :stop, priority: 99
        end
        query_state(index)
    end

    def query_state(index = 1)
        index = relative_address(index)
        send "#{Commands[:status]} #{index} #{32}\r\n"
    end


    protected


    def relative_address(index)
        index + 16
    end

    Status = {
        0 => :moving_top,
        1 => :moving_bottom,
        2 => :moving_preset_1,
        3 => :moving_preset_2,
        4 => :moving_top,       # preset top
        5 => :moving_bottom,    # preset bottom
        6 => :at_top,
        7 => :at_bottom,
        8 => :at_preset_1,
        9 => :at_preset_2,
        10 => :stopped,
        11 => :error,
        # 12 => undefined
        13 => :error_timeout,
        14 => :error_current,
        15 => :error_rattle,
        16 => :at_bottom   # preset bottom
    }

    def received(data, resolve, command)
        logger.debug { "Screen sent #{data}" }

        # Builds an array of numbers from the returned string
        parts = data.split(/,\s*/).map { |part| part.strip.to_i }
        cmd = Commands[parts[0] - 100]

        if cmd
            index = parts[2] - 16

            case cmd
            when :up
                logger.debug { "Screen#{index} moving up" }
            when :down
                logger.debug { "Screen#{index} moving down" }
            when :stop
                logger.debug { "Screen#{index} stopped" }
            when :status
                self[:"screen#{index}"] = Status[parts[-1]]
            end
        else
            logger.debug { "Unknown command #{parts[0]}" }
        end
    end
end
