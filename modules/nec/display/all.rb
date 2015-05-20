module Nec; end
module Nec::Display; end

# :title:All NEC Control Module
#
# Controls all LCD displays as of 1/07/2011
# Status information avaliable:
# -----------------------------
#
# (built in)
# connected
#
# (module defined)
# power
# warming
#
# volume
# volume_min == 0
# volume_max
#
# brightness
# brightness_min == 0
# brightness_max
#
# contrast
# contrast_min = 0
# contrast_max
# 
# audio_mute
# 
# input (video input)
# audio (audio input)
#
#
class Nec::Display::All
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    #
    # Called on module load complete
    #    Alternatively you can use initialize however will
    #    not have access to settings and this is called
    #    soon afterwards
    #
    def on_load
        #
        # Setup constants
        #
        config({
            tokenize: true,
            delimiter: "\x0D",
            encoding: "ASCII-8BIT"
        })

        defaults({
            timeout: 5000,
            delay: 100
        })

        on_update
    end

    def on_update
        self[:volume_min] = setting(:volume_min) || 0
        self[:volume_max] = setting(:volume_max) || 100
        self[:brightness_min] = 0
        self[:contrast_min] = 0
    end

    def connected
        do_poll

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


    #
    # Power commands
    #
    def power(state)
        message = "C203D6"

        current = self[:power]
        if is_affirmative?(state)
            if current == Off
                message += "0001"    # Power On
                send_checksum(:command, message, {:name => :power, :delay => 5000})
                self[:warming] = true
                self[:power] = On
                logger.debug "-- NEC LCD, requested to power on"

                power_on_delay
                mute_status(99)
                volume_status(99)
            end
        else
            if current == On
                message += "0004"    # Power Off
                send_checksum(:command, message, {:name => :power, :delay => 10000, :timeout => 10000})

                self[:power] = Off
                logger.debug "-- NEC LCD, requested to power off"
            end
        end
    end

    def power?(options = {}, &block)
        options[:emit] = block if block_given?
        type = :command
        message = "01D6"
        send_checksum(type, message, options)
    end


    #
    # Input selection
    #
    INPUTS = {
        :vga => 1,
        :rgbhv => 2,
        :dvi => 3,
        :hdmi_set => 4,    # Set only?
        :video1 => 5,
        :video2 => 6,
        :svideo => 7,

        :tv => 10,
        :dvd1 => 12,
        :option => 13,
        :dvd2 => 14,
        :display_port => 15,

        :hdmi => 17
    }
    def switch_to(input)
        input = input.to_sym if input.class == String
        #self[:target_input] = input

        type = :set_parameter
        message = OPERATION_CODE[:video_input]
        message += INPUTS[input].to_s(16).upcase.rjust(4, '0')    # Value of input as a hex string

        send_checksum(type, message, {:name => :input})
        brightness_status(20)        # higher status than polling commands - lower than input switching
        contrast_status(20)

        logger.debug "-- NEC LCD, requested to switch to: #{input}"
    end

    AUDIO = {
        :audio1 => 1,
        :audio2 => 2,
        :audio3 => 3,
        :hdmi => 4,
        :tv => 6,
        :display_port => 7
    }
    def switch_audio(input)
        input = input.to_sym if input.class == String
        #self[:target_audio] = input

        type = :set_parameter
        message = OPERATION_CODE[:audio_input]
        message += AUDIO[input].to_s(16).upcase.rjust(4, '0')    # Value of input as a hex string

        send_checksum(type, message, :name => :audio)
        mute_status(20)        # higher status than polling commands - lower than input switching
        volume_status(20)

        logger.debug "-- NEC LCD, requested to switch audio to: #{input}"
    end


    #
    # Auto adjust
    #
    def auto_adjust
        message = OPERATION_CODE[:auto_setup] #"001E"    # Page + OP code
        message += "0001"    # Value of input as a hex string

        send_checksum(:set_parameter, message, :delay_on_receive => 4.0)
    end


    #
    # Value based set parameter
    #
    def brightness(val)
        val = in_range(val.to_i, 100)

        message = OPERATION_CODE[:brightness_status]
        message += val.to_s(16).upcase.rjust(4, '0')    # Value of input as a hex string

        send_checksum(:set_parameter, message)
        send_checksum(:command, '0C')    # Save the settings
        brightness_status
    end

    def contrast(val)
        val = in_range(val.to_i, 100)

        message = OPERATION_CODE[:contrast_status]
        message += val.to_s(16).upcase.rjust(4, '0')    # Value of input as a hex string

        send_checksum(:set_parameter, message)
        send_checksum(:command, '0C')    # Save the settings
        contrast_status
    end

    def volume(val)
        val = in_range(val.to_i, 100)

        message = OPERATION_CODE[:volume_status]
        message += val.to_s(16).upcase.rjust(4, '0')    # Value of input as a hex string

        send_checksum(:set_parameter, message)
        send_checksum(:command, '0C')    # Save the settings
        volume_status

        self[:audio_mute] = false    # audio is unmuted when the volume is set
    end

    
    def mute_audio(state = true)
        message = OPERATION_CODE[:mute_status]
        message += is_affirmative?(state) ? "0001" : "0000"    # Value of input as a hex string

        send_checksum(:set_parameter, message)

        logger.debug "requested to update mute to #{state}"
    end
    alias_method :mute, :mute_audio

    def unmute_audio
        mute_audio(false)
    end
    alias_method :unmute, :unmute_audio

    #
    # LCD Response code
    #
    def received(data, resolve, command)
        #
        # Check for valid response
        #
        if !check_checksum(data)
            logger.debug "-- NEC LCD, checksum failed for command: #{command[:data]}" if command
            logger.debug "-- NEC LCD, response was: #{data}"
            return false
        end

        logger.debug { "NEC LCD responded #{data}" }

        case MSG_TYPE[data[4]]    # Check the MSG_TYPE (B, D or F)
            when :command_reply
                #
                # Power on and off
                #    8..9 == "00" means no error 
                if data[10..15] == "C203D6"    # Means power comamnd
                    if data[8..9] == "00"
                        power_on_delay(99)    # wait until the screen has turned on before sending commands (99 == high priority)
                    else
                        logger.info "-- NEC LCD, command failed: #{command[:data]}" if command
                        logger.info "-- NEC LCD, response was: #{data}"
                        return false    # command failed
                    end
                elsif data[10..13] == "00D6"    # Power status response
                    if data[10..11] == "00"
                        if data[23] == '1'        # On == 1, Off == 4
                            self[:power] = On
                        else
                            self[:power] = Off
                            self[:warming] = false
                        end
                    else
                        logger.info "-- NEC LCD, command failed: #{command[:data]}" if command
                        logger.info "-- NEC LCD, response was: #{data}"
                        return false    # command failed
                    end

                end

            when :get_parameter_reply, :set_parameter_reply
                if data[8..9] == "00"
                    parse_response(data, command)
                elsif data[8..9] == 'BE'    # Wait response
                    send(command[:data])    # checksum already added
                    logger.debug "-- NEC LCD, response was a wait command"
                else
                    logger.info "-- NEC LCD, get or set failed: #{command[:data]}" if command
                    logger.info "-- NEC LCD, response was: #{data}"
                    return false
                end
        end

        return true # Command success
    end


    def do_poll
        power?({:priority => 0}) do
            logger.debug { "Polling, power = #{self[:power]}" }

            if self[:power] == On
                power_on_delay
                mute_status
                volume_status
                brightness_status
                contrast_status
                video_input
                audio_input
            end
        end
    end


    private


    def parse_response(data, command)

        # 14..15 == type (we don't care)
        max = data[16..19].to_i(16)
        value = data[20..23].to_i(16)

        case OPERATION_CODE[data[10..13]]
            when :video_input
                self[:input] = INPUTS.invert[value]
                #self[:target_input] = self[:input] if self[:target_input].nil?
                #switch_to(self[:target_input]) unless self[:input] == self[:target_input]

            when :audio_input
                self[:audio] = AUDIO.invert[value]
                #self[:target_audio] = self[:audio] if self[:target_audio].nil?
                #switch_audio(self[:target_audio]) unless self[:audio] == self[:target_audio]

            when :volume_status
                self[:volume_max] = max
                if not self[:audio_mute]
                    self[:volume] = value
                end

            when :brightness_status
                self[:brightness_max] = max
                self[:brightness] = value

            when :contrast_status
                self[:contrast_max] = max
                self[:contrast] = value

            when :mute_status
                self[:audio_mute] = value == 1
                if(value == 1)
                    self[:volume] = 0
                else
                    volume_status(0)    # high priority
                end

            when :power_on_delay
                if value > 0
                    self[:warming] = true
                    schedule.in("#{value}s") do        # Prevent any commands being sent until the power on delay is complete
                        power_on_delay
                    end
                else
                    schedule.in('3s') do        # Reactive the interface once the display is online
                        self[:warming] = false    # allow access to the display
                    end
                end
            when :auto_setup
                # auto_setup
                # nothing needed to do here (we are delaying the next command by 4 seconds)
            else
                logger.info "-- NEC LCD, unknown response: #{data[10..13]}"
                logger.info "-- NEC LCD, for command: #{command[:data]}" if command
                logger.info "-- NEC LCD, full response was: #{data}"
        end
    end


    #
    # Types of messages sent to and from the LCD
    #
    MSG_TYPE = {
        :command => 'A',
        'B' => :command_reply,
        :get_parameter => 'C',
        'D' => :get_parameter_reply,
        :set_parameter => 'E',
        'F' => :set_parameter_reply
    }


    OPERATION_CODE = {
        :video_input => '0060', '0060' => :video_input,
        :audio_input => '022E', '022E' => :audio_input,
        :volume_status => '0062', '0062' => :volume_status,
        :mute_status => '008D', '008D' => :mute_status,
        :power_on_delay => '02D8', '02D8' => :power_on_delay,
        :contrast_status => '0012', '0012' => :contrast_status,
        :brightness_status => '0010', '0010' => :brightness_status,
        :auto_setup => '001E', '001E' => :auto_setup
    }
    #
    # Automatically creates a callable function for each command
    #    http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
    #    http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
    #
    OPERATION_CODE.each_key do |command|
        define_method command do |*args|
            priority = 0
            if args.length > 0
                priority = args[0]
            end

            logger.debug { "NEC requesting #{command}" }

            message = OPERATION_CODE[command]
            send_checksum(:get_parameter, message, {:priority => priority})    # Status polling is a low priority
        end
    end


    def check_checksum(data)
        data = str_to_array(data)

        check = 0
        #
        # Loop through the second to the second last element
        #    Delimiter is removed automatically
        #
        if data.length >= 2
            data[1..-2].each do |byte|
                check = check ^ byte
            end
            return check == data[-1]    # Check the check sum equals the last element
        else
            return true
        end
    end


    #
    # Builds the command and creates the checksum
    #
    def send_checksum(type, command, options = {})
        #
        # build header + command and convert to a byte array
        #
        command = "" << 0x02 << command << 0x03
        command = "0*0#{MSG_TYPE[type]}#{command.length.to_s(16).upcase.rjust(2, '0')}#{command}"
        command = str_to_array(command)

        #
        # build checksum
        #
        check = 0
        command.each do |byte|
            check = check ^ byte
        end

        command << check    # Add checksum
        command << 0x0D        # delimiter required by NEC displays
        command.insert(0, 0x01)    # insert SOH byte (not part of the checksum)

        send(command, options)
    end
end

