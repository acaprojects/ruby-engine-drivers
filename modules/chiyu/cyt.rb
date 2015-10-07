module Chiyu; end


# Normal state for inputs == open
# IO Operations mode TCP server
# Periodically every second


# Default port: 50001
class Chiyu::Cyt
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # this will ignore the CRC check byte
    tokenise delimiter: "\xF0\xF0", min_length: 2
    delay on_receive: 500


    def on_load
        @outputs = Array.new(32, 1)
    end
    
    def on_update
    end
    
    def connected
        do_send(:state)
        do_send(:auto_report)

        @polling_timer = schedule.every('60s') do
            do_send(:state)
        end
    end
    
    def disconnected
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end



    COMMANDS = {
        state: [0x00, 0x01],
        trigger: [0x00, 0x03],
        auto_report: [0x00, 0x05],
        ack_keepalive: [0x00, 0x08]
    }

    RESPONSES = {
        [0x00, 0x02] => :state,
        [0x00, 0x04] => :trigger,
        [0x00, 0x06] => :emailed,
        [0x00, 0x10] => :report,
        [0x00, 0x07] => :keepalive,
        [0x00, 0x08] => :keepalive
    }

    ERRORS = {
        0xFC => 'Flag error, incorrect Start Flag or End Flag'.freeze,
        0xFD => 'Length error, the length of command packet is invalid'.freeze,
        0xFE => 'CRC error, incorrect CRC value'.freeze,
        0xFF => 'Command error, no such command'.freeze
    }
    
    
    
    def relay(index, state, time = nil)
        index = index - 1
        return if index >= 30 || index < 0

        @outputs[index] = is_affirmative?(state) ? 0 : 1
        opts = {
            data1: @outputs
        }

        if time
            time = time.to_i
            times = Array.new(32, 0)
            times[index] = time
            opts[:data2] = times
            opts[:delay_on_receive] = time * 1000 + 1200
        end

        do_send(:trigger, opts)
        self[:"relay#{index + 1}"] = true
    end

    # According to the manual we have to use UDP on port 5050 to signal a reboot
    def reboot
        data = "CHIYU Reboot CMD\x00\x00\x00\x20"
        thread.udp_service.send(remote_address, 5050, data)
    end
    
    
    
    def received(data_str, resolve, command)
        data = str_to_array(data_str)
        logger.debug "Chiyu sent #{data}"

        cmd = data[0..1]
        data1 = data[2..33]
        data2 = data[34..65]

        if cmd[0] != 0xFF
            case RESPONSES[cmd]
            when :state, :report
                data1.each_index do |index|
                    next if index >= 30
                    byte = data1[index]
                    if byte < 2
                        self[:"sensor#{index + 1}"] = byte == 1
                    end
                end

                @outputs = data2
                data2.each_index do |index|
                    next if index >= 30
                    byte = data2[index]
                    if byte < 2
                        self[:"relay#{index + 1}"] = byte == 0
                    end
                end
            when :keepalive
                do_send(:ack_keepalive)
            end
            
            :success
        else
            # Error
            error = ERRORS[cmd[1]]
            self[:last_error] = error
            logger.debug "Chiyu error #{error}"
            :abort
        end
    end



    # Pulse Lifter Logic
    #
    # Automatically creates a callable function for each command
    #   http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
    #   http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
    #
    [:up, :down, :left, :right].each do |helper|
        define_method helper do |*args|
            index = args[0] || setting(helper) || 1
            index = index.to_i

            relay(index, true, 2)
            relay(index, true, 2)
        end
    end

    
    
    protected


    def checksum!(command)
        check = 0
        command.each do |byte|
            check = check + byte
        end
        check = (0 - check) & 0xFF
        command << check
    end


    FLAG = [0xF0, 0xF0]
    EMPTY = Array.new(32, 0)
    
    
    def do_send(command, options = {})
        cmd = FLAG + COMMANDS[command]
        cmd += options.delete(:data1) || EMPTY
        cmd += options.delete(:data2) || EMPTY
        cmd += FLAG
        checksum!(cmd)

        options[:name] = command unless options[:name]

        send(cmd, options)
        logger.debug "-- CYT, sending: #{command}"
    end
end

