module Chiyu; end


class Chiyu::Cyt
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    def on_load
        @inputs = Array.new(32, 2)
        @outputs = Array.new(32, 0)

        config({
            tokenize: true,
            delimiter: "\xF0\xF0",
            min_length: 2 # this will ignore the CRC check byte
        })
    end
    
    def on_update
    end
    
    # No keep alive required as the device polls us
    def connected
        do_send(:state)
        do_send(:auto_report)
    end
    
    def disconnected
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
        [0x00, 0x07] => :keepalive
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

        @outputs[index] = is_affirmative?(state) ? 1 : 0
        opts = {
            data1: @outputs
        }

        if time
            times = Array.new(32, 0)
            times[index] = time
            opts[:data2] = times
        end

        do_send(:trigger, opts)
        self[:"relay#{index}"] = true
    end
    
    
    
    def received(data_str, resolve, command)
        data = str_to_array(byte_str)
        logger.debug "Chiyu sent #{data}"

        cmd = data[0..2]
        data1 = data[3..34]
        data2 = data[35..66]

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

                data2.each_index do |index|
                    next if index >= 30
                    byte = data2[index]
                    if byte < 2
                        self[:"relay#{index + 1}"] = byte == 1
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

        send(command, options)
        logger.debug "-- CYT, sending: #{command}"
    end
end

