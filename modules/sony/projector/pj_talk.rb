module Sony; end
module Sony::Projector; end


class Sony::Projector::PjTalk
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 53484
    descriptive_name 'Sony PJ Talk Projector'
    generic_name :Display

    # Communication settings
    tokenize indicator: "\x02\x0a", callback: :check_complete
    delay on_receive: 200


    def on_load
        self[:brightness_min] = 0x00
        self[:brightness_max] = 0x64
        self[:contrast_min] = 0x00
        self[:contrast_max] = 0x64

        self[:power] = false
        self[:type] = :projector

        on_update
    end

    def on_update
        # Default community value is SONY - can be changed in displays settings
        @community = str_to_array(setting(:community) || 'SONY')
    end
    

    def connected
        @polling_timer = schedule.every('60s', method(:do_poll))
    end

    def disconnected
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end
    
    
    #
    # Power commands
    #
    def power(state)
        if is_affirmative?(state)
            do_send(:set, :power_on, name: :power, delay_on_receive: 3000)
            logger.debug "-- sony display requested to power on"
        else
            do_send(:set, :power_off, name: :power, delay_on_receive: 3000)
            logger.debug "-- sony display requested to power off"
        end

        # Request status update
        power?
    end

    def power?(options = {}, &block)
        options[:emit] = block if block_given?
        options[:priority] = 0
        do_send(:get, :power_status, options)
    end
    
    
    
    #
    # Input selection
    #
    INPUTS = {
        :vga => [0x00, 0x03],
        :dvi => [0x00, 0x04],
        :hdmi => [0x00, 0x05]
    }
    INPUTS.merge!(INPUTS.invert)
    
    
    def switch_to(input)
        input = input.to_sym
        return unless INPUTS.has_key? input
        
        do_send(:set, :input, INPUTS[input], delay_on_receive: 500)
        logger.debug { "-- sony projector, requested to switch to: #{input}" }
        
        input?
    end

    def input?
        do_send(:get, :input, {:priority => 0})
    end

    def lamp_time?
        do_send(:get, :lamp_timer, {:priority => 0})
    end
    
    
    #
    # Mute Audio and Video
    #
    def mute(val = true)
        logger.debug "-- sony projector, requested to mute"

        actual = is_affirmative?(val) ? [0x00, 0x01] : [0x00, 0x00]
        do_send(:set, :mute, actual, delay_on_receive: 500)
    end

    def unmute
        logger.debug "-- sony projector, requested to unmute"
        mute(false)
    end

    def mute?
        do_send(:get, :mute, {:priority => 0})
    end


    #
    # Automatically creates a callable function for each command
    #    http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
    #    http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
    #
    [:contrast, :brightness, :color, :hue, :sharpness].each do |command|
        # Query command
        define_method :"#{command}?" do
            do_send(:get, command, {:priority => 0})
        end

        # Set value command
        define_method command do |level|
            level = in_range(level, 0x64)
            do_send(:set, command, [0x00, level])
            __send__(:"#{command}?")
        end
    end

    
    ERRORS = {
        0x00 => 'No Error'.freeze,
        0x01 => 'Lamp Error'.freeze,
        0x02 => 'Fan Error'.freeze,
        0x04 => 'Cover Error'.freeze,
        0x08 => 'Temperature Error'.freeze,
        0x10 => 'D5V Error'.freeze,
        0x20 => 'Power Error'.freeze,
        0x40 => 'Warning Error'.freeze
    }


    def received(byte_str, resolve, command)        # Data is default received as a string
        # Remove community string (useless)
        logger.debug { "sony proj sent: 0x#{byte_to_hex(byte_str[4..-1])}" }

        data = str_to_array(byte_str)
        pjt_command = data[5..6]
        pjt_length = data[7]
        pjt_data = data[8..-1]

        if data[4] == 0x01
            case COMMANDS[pjt_command]
            when :power_on
                self[:power] = On
            when :power_off
                self[:power] = Off
            when :lamp_timer
                # Two bytes converted to a 16bit integer
                # Response looks like: 0x01 01 13 (02 03) <- lamp hours
                self[:lamp_usage] = array_to_str(data[-2..-1]).unpack('n')[0]
            else
                # Same switch however now we know there is data
                if pjt_length && pjt_length > 0
                    case COMMANDS[pjt_command]
                    when :power_status
                        case pjt_data[-1]
                        when 0, 8
                            self[:warming] = self[:cooling] = self[:power] = false
                        when 1, 2
                            self[:cooling] = false
                            self[:warming] = self[:power] = true
                        when 3
                            self[:power] = true
                            self[:warming] = self[:cooling] = false
                        when 4, 5, 6, 7
                            self[:cooling] = true
                            self[:warming] = self[:power] = false
                        end

                        if self[:warming] || self[:cooling]
                            schedule.in '10s' do
                                power?
                            end
                        end
                    when :mute
                        self[:mute] = pjt_data[-1] == 1
                    when :input
                        self[:input] = INPUTS[pjt_data]
                    when :contrast, :brightness, :color, :hue, :sharpness
                        self[COMMANDS[pjt_command]] = pjt_data[-1]
                    when :error_status

                    end
                end
            end
        else
            # Command failed..
            self[:last_error] = pjt_data
            logger.debug { "Command #{pjt_command} failed with Major 0x#{byte_to_hex(pjt_data[0])} and Minor 0x#{byte_to_hex(pjt_data[1])}" }
            return :abort
        end

        :success
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
                do_send(:get, :error_status, {:priority => 0})
                lamp_time?
            end
        end
    end

    # Constants as per manual page 13
    # version, category
    PjTalk_Header = [0x02, 0x0a]


    # request, category, command
    COMMANDS = {
        power_on: [0x17, 0x2E],
        power_off: [0x17, 0x2F],
        input: [0x00, 0x01],
        mute: [0x00, 0x30],

        error_status: [0x01, 0x01],
        power_status: [0x01, 0x02],

        contrast: [0x00, 0x10],
        brightness: [0x00, 0x11],
        color: [0x00, 0x12],
        hue: [0x00, 0x13],
        sharpness: [0x00, 0x14],
        lamp_timer: [0x01, 0x13]
    }
    COMMANDS.merge!(COMMANDS.invert)


    def do_send(getset, command, param = nil, options = {})
        # Check for missing params
        if param.is_a? Hash
            options = param
            param = nil
        end

        reqres = getset == :get ? [0x01] : [0x00]

        # Control + Mode
        if param.nil?
            options[:name] = command if options[:name].nil?
            cmd = COMMANDS[command] + [0x00]
        else
            options[:name] = :"#{command}_req" if options[:name].nil?
            if !param.is_a?(Array)
                param = [param]
            end
            cmd = COMMANDS[command] + [param.length] + param
        end

        # Build the IDTalk header         # set request every time?
        pjt_cmd = PjTalk_Header + @community + reqres + cmd

        send(pjt_cmd, options)
    end
end
