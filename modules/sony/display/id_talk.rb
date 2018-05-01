module Sony; end
module Sony::Display; end

# Documentation: https://aca.im/driver_docs/Sony/FWDS42-47H1protocol.pdf

class Sony::Display::IdTalk
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 53484
    descriptive_name 'Sony ID Talk LCD Monitor'
    generic_name :Display

    # Communication settings
    tokenize indicator: "\x02\x10", callback: :check_complete


    def on_load
        self[:brightness_min] = 0x00
        self[:brightness_max] = 0x64
        self[:contrast_min] = 0x00
        self[:contrast_max] = 0x64
        self[:volume_min] = 0x00
        self[:volume_max] = 0x64

        self[:power] = false
        self[:type] = :lcd

        on_update
    end

    def on_update
        # Default community value is SONY - can be changed in displays settings
        @community = str_to_array(setting(:community) || 'SONY')
    end
    

    def connected
        schedule.every('60s') { do_poll }
    end

    def disconnected
        schedule.clear
    end
    
    
    
    #
    # Power commands
    #
    def power(state, opt = nil)
        if is_affirmative?(state)
            do_send(:power, 1)
            logger.debug "-- sony display requested to power on"
        else
            do_send(:power, 0)
            logger.debug "-- sony display requested to power off"
        end

        # Request status update
        power?
    end

    def power?(options = {}, &block)
        options[:emit] = block if block_given?
        options[:priority] = 0
        do_send(:power, options)
    end
    
    
    
    #
    # Input selection
    #
    INPUTS = {
        :vga => 0x08,
        :dvi => 0x20,
        :hdmi => 0x44,
        :hdmi2 => 0x84,
        :hdmi3 => 0x85
    }
    INPUTS.merge!(INPUTS.invert)
    
    
    def switch_to(input)
        input = input.to_sym
        return unless INPUTS.has_key? input
        
        do_send(:input, INPUTS[input])
        logger.debug { "-- sony display, requested to switch to: #{input}" }
        
        input?
    end

    def input?
        do_send(:input, {:priority => 0})
    end
    
    
    #
    # Mute Audio and Video
    #
    def mute
        logger.debug "-- sony display, requested to mute"
        do_send(:mute, 1)
        mute?
    end

    def unmute
        logger.debug "-- sony display, requested to unmute"
        do_send(:mute, 0)
        mute?
    end

    def mute?
        do_send(:mute, {:priority => 0})
    end

    def mute_audio
        logger.debug "-- sony display, requested to mute audio"
        do_send(:audio_mute, 1)
        audio_mute?
    end

    def unmute_audio
        logger.debug "-- sony display, requested to unmute audio"
        do_send(:audio_mute, 0)
        audio_mute?
    end

    def audio_mute?
        do_send(:audio_mute, {:priority => 0})
    end


    #
    # Automatically creates a callable function for each command
    #    http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
    #    http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
    #
    [:contrast, :brightness, :volume].each do |command|
        # Query command
        define_method :"#{command}?" do
            do_send(command, {:priority => 0})
        end

        # Set value command
        define_method command do |level|
            do_send(command, level)
            __send__(:"#{command}?")
        end
    end

    
    
    ERRORS = {
        :ERR1 => '1: Undefined control command'.freeze,
        :ERR2 => '2: Out of parameter range'.freeze,
        :ERR3 => '3: Busy state or no-acceptable period'.freeze,
        :ERR4 => '4: Timeout or no-acceptable period'.freeze,
        :ERR5 => '5: Wrong data length'.freeze,
        :ERRA => 'A: Password mismatch'.freeze
    }

    RESP = {
        0x00 => :success,
        0x01 => :limit_over,
        0x02 => :limit_under,
        0x03 => :cancelled
    }
    

    def received(byte_str, resolve, command)        # Data is default received as a string
        logger.debug { "sony display sent: 0x#{byte_to_hex(data)}" }

        data = str_to_array(byte_str)
        idt_command = data[5..6]
        resp = data[8..-1]

        if data[4] == 0x01
            # resp is now equal to the unit control codes

            type = RESP[resp[1]]

            case type
            when :success
                if resp.length > 3 && command
                    # This is a request response
                    cmd = command[:name]

                    case cmd
                    when :power, :audio_mute, :mute
                        self[cmd] = resp[3] == 0x01
                    when :input
                        self[cmd] = INPUTS[resp[3]]
                    when :signal_status
                        self[cmd] = resp[3] != 0x01
                    when :contrast, :brightness, :volume
                        self[cmd] = resp[3]
                    end
                end
                return :success
            when :limit_over, :limit_under
                warning = "sony display sent a value that was #{type}"
                warning += " for command #{command[:name]}" if command

                logger.warn warning 

                return :abort
            when :cancelled
                # Attempt the request again
                return :retry
            end

        else
            # Command failed.. value == error code
            return :abort
        end
    end

    
    
    protected


    # Called by the Abstract Tokenizer to confirm we have the
    # whole message.
    def check_complete(byte_str)
        bytes = str_to_array(byte_str)

        # Min message length is 8 bytes
        return false if bytes.length < 8

        # Check we have the data
        data = bytes[8..-1]
        if data.length >= bytes[7]
            # Let the tokeniser know we only want the following number of bytes
            return 7 + bytes[7]
        end

        # Still waiting on data
        return false
    end
    
    
    def do_poll(*args)
        power?({:priority => 0}) do
            if self[:power]
                input?
                mute?
                audio_mute?
                volume?
                do_send(:signal_status, {:priority => 0})
            end
        end
    end

    # Constants as per manual page 18
    # version, category
    IdTalk_Header = [0x02, 0x10]

    # Unit protocol as per manual page 21
    # Dedicated unit protocol
    IdTalk_Type = [0xF1, 0x00]


            # category, command
    COMMANDS = {
        power: [0x00, 0x00],
        input: [0x00, 0x01],
        audio_mute: [0x00, 0x03],
        signal_status: [0x00, 0x75],
        mute: [0x00, 0x8D],

        contrast: [0x10, 0x00],
        brightness: [0x10, 0x01],
        volume: [0x10, 0x30]
    }
    COMMANDS.merge!(COMMANDS.invert)


    def build_checksum(command)
        check = 0
        command.each do |byte|
            check = (check + byte) & 0xFF
        end
        [check]
    end


    def do_send(command, param = nil, options = {})
        # Check for missing params
        if param.is_a? Hash
            options = param
            param = nil
        end

        # Control + Mode
        if param.nil?
            options[:name] = command
            cmd = [0x83] + COMMANDS[command] + [0xFF, 0xFF]
        else
            options[:name] = :"#{command}_cmd"
            type = [0x8C] + COMMANDS[command]
            if !param.is_a?(Array)
                param = [param]
            end
            data = [param.length + 1] + param
            cmd = type + data
        end

        cmd = cmd + build_checksum(cmd)

        # Build the IDTalk header         # set request every time?
        idt_cmd = IdTalk_Header + @community + [0x00] + IdTalk_Type + [cmd.length] + cmd

        send(idt_cmd, options)
    end
end

