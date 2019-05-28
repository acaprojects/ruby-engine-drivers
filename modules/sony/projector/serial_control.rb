# encoding: ASCII-8BIT
# frozen_string_literal: true

module Sony; end
module Sony::Projector; end

# Documentation: https://aca.im/driver_docs/Sony/Sony_Q004_R1_protocol.pdf
#  also https://aca.im/driver_docs/Sony/TCP_CMDs.pdf

class Sony::Projector::SerialControl
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    descriptive_name 'Sony Projector (RS232 Control)'
    generic_name :Display

    # Communication settings
    tokenize indicator: "\xA9", msg_length: 7
    delay on_receive: 50, between_sends: 50


    def on_load
        self[:type] = :projector
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
    def power(state)
        if is_affirmative?(state)
            # Need to send twice in case of deep sleep
            do_send(:set, :power_on, name: :power, wait: false)
            do_send(:set, :power_on, name: :power, delay: 3000, wait: false)
            logger.debug 'requested to power on'
        else
            do_send(:set, :power_off, name: :power, delay: 3000, wait: false)
            logger.debug 'requested to power off'
        end

        # Request status update
        power? priority: 50
    end

    def power?(**options, &block)
        options[:emit] = block if block_given?
        options[:priority] ||= 0
        do_send(:get, :power_status, options)
    end

    #
    # Input selection
    #
    INPUTS = {
        hdmi: [0x00, 0x03], #aka inputb
        inputa: [0x00, 0x02],
        inputb: [0x00, 0x03],
        inputc: [0x00, 0x04],
        inputd: [0x00, 0x05],
        usb:  [0x00, 0x06], # usb type B
        network: [0x00, 0x07] # network
    }
    INPUTS.merge!(INPUTS.invert)

    def switch_to(input)
        input = input.to_sym
        raise 'unknown input' unless INPUTS.has_key? input

        do_send(:set, :input, INPUTS[input], delay_on_receive: 500)
        logger.debug { "requested to switch to: #{input}" }

        input?
    end

    def input?
        do_send(:get, :input, priority: 0)
    end

    def lamp_time?
        do_send(:get, :lamp_timer, priority: 0)
    end

    #
    # Mute Audio and Video
    #
    def mute(val = true)
        logger.debug 'requested to mute'

        actual = is_affirmative?(val) ? [0x00, 0x00] : [0x00, 0x01]
        do_send(:set, :mute, actual, delay_on_receive: 500)
    end

    def unmute
        logger.debug 'requested to unmute'
        mute(false)
    end

    def mute?
        do_send(:get, :mute, priority: 0)
    end


    #
    # Automatically creates a callable function for each command
    #    http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
    #    http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
    #
    [:contrast, :brightness, :color, :hue, :sharpness].each do |command|
        # Query command
        define_method :"#{command}?" do
            do_send(:get, command, priority: 0)
        end

        # Set value command
        define_method command do |level|
            level = in_range(level, 0x64)
            do_send(:set, command, [0x00, level])
            __send__(:"#{command}?")
        end
    end

    
    ERRORS = {
        0x00 => 'No Error',
        0x01 => 'Lamp Error',
        0x02 => 'Fan Error',
        0x04 => 'Cover Error',
        0x08 => 'Temperature Error',
        0x10 => 'D5V Error',
        0x20 => 'Power Error',
        0x40 => 'Warning Error',
        0x80 => 'NVM Data ERROR'
    }


    def received(byte_str, resolve, command)
        # Remove community string (useless)
        logger.debug { "sony proj sent: 0xA9#{byte_to_hex(byte_str)}" }

        data = str_to_array(byte_str)
        cmd = data[0..1]
        type = data[2]
        resp = data[3..4]

        # Check if an ACK/NAK
        if type == 0x03
            if cmd == [0, 0]
                return :success
            else
                # Command failed..
                logger.debug { "Command failed with 0x#{byte_to_hex(cmd[0])} - 0x#{byte_to_hex(cmd[1])}" }
                return :abort
            end
        else
            case COMMANDS[cmd]
            when :power_on
                self[:power] = On
            when :power_off
                self[:power] = Off
            when :lamp_timer
                # Two bytes converted to a 16bit integer
                self[:lamp_usage] = array_to_str(data[-2..-1]).unpack('n')[0]
            when :power_status
                case resp[-1]
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
                    schedule.in '5s' do
                        power?
                    end
                end
            when :mute
                self[:mute] = resp[-1] == 1
            when :input
                self[:input] = INPUTS[resp]
            when :contrast, :brightness, :color, :hue, :sharpness
                self[COMMANDS[cmd]] = resp[-1]
            # when :error_status
            end
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
        false
    end

    def do_poll(*args)
        power?(priority: 0).finally do
            if self[:power]
                input?
                mute?
                do_send(:get, :error_status, priority: 0)
                lamp_time?
            end
        end
    end

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

    def checksum(cmd)
        check = 0
        cmd.each { |byte| check |= byte }
        check
    end

    def do_send(getset, command, param = [0x00, 0x00], **options)
        cmd = COMMANDS[command]

        if getset == :get
            options[:name] = :"#{command}_req" if options[:name].nil?
            type = [0x01]
        else
            options[:name] = command if options[:name].nil?
            type = [0x00]
        end

        param = Array(param)
        param.unshift(0) if param.length < 2

        # Build the request
        cmd = cmd + type + param
        cmd << checksum(cmd)
        cmd << 0x9A
        cmd.unshift(0xA9)

        send(cmd, options)
    end
end
