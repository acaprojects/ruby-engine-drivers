module Sharp; end
module Sharp::Displays; end


# :title:All Sharp Control Module
#
# Controls all LCD displays as of 1/10/2011
# Status information avaliable:
# -----------------------------
#
# (built in)
# connected
#
# (module defined)
# power
# warming
# power_on_delay
#
# volume
# volume_min == 0
# volume_max == 31
#
# brightness
# brightness_min == 0
# brightness_max == 31
#
# contrast
# contrast_min == 0
# contrast_max == 60
# 
# audio_mute
# 
# input (video input)
# audio (audio input)
#
#
class Sharp::Displays::PnSeries
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    clear_queue_on_disconnect!
    delay on_receive: 120
    wait_response timeout: 6000

    tokenize delimiter: "\x0D\x0A", wait_ready: "login:"


    #
    # Called on module load complete
    #    Alternatively you can use initialize however will
    #    not have access to settings and this is called
    #    soon afterwards
    #
    def on_load
        on_update
    end

    def on_update
        self[:volume_min] = 0
        self[:volume_max] = 31
        self[:brightness_min] = 0
        self[:brightness_max] = 31
        self[:contrast_min] = 0
        self[:contrast_max] = 60    # multiply by two when VGA selected
    end

    def connected
        # Will be sent after login is requested (config - wait ready)
        send_credentials

        @polling_timer = schedule.every('60s') do
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
        delay = self[:power_on_delay] || 5000

        result = self[:power]
        if is_affirmative?(state)
            if result == Off
                do_send('POWR   1', {:timeout => delay + 15000, :name => :POWR})
                self[:warming] = true
                self[:power] = On
                logger.debug "-- Sharp LCD, requested to power on"

                do_send('POWR????', {:timeout => 10000, :value_ret_only => :POWR})    # clears warming
            end
        else
            if result == On
                do_send('POWR   0', {:timeout => 15000, :name => :POWR})

                self[:power] = Off
                logger.debug "-- Sharp LCD, requested to power off"
            end
        end

        mute_status(0)
        volume_status(0)
    end

    def power?(options = {}, &block)
        block.call(self[:power]) unless block.nil?
    end


    def power_state?(options = {}, &block)
        options[:emit] = block unless block.nil?
        options.merge!({:timeout => 10000, :value_ret_only => :POWR})
        do_send('POWR????', options)
    end


    #
    # Resets the brightness and contrast settings
    #
    def reset
        do_send('ARST   2')
    end


    #
    # Input selection
    #
    INPUTS = {
        :dvi => 'INPS0001', 1 => :dvi,
        :hdmi => 'INPS0010', 10 => :hdmi,
        :hdmi2 => 'INPS0013', 13 => :hdmi2,
        :hdmi3 => 'INPS0018', 18 => :hdmi3,
        :display_port => 'INPS0014', 14 => :display_port,
        :vga => 'INPS0002', 2 => :vga,
        :vga2 => 'INPS0016', 16 => :vga2,
        :component => 'INPS0003', 3 => :component,
        :unknown => 'INPS????'
    }
    def switch_to(input)
        input = input.to_sym if input.class == String

        #self[:target_input] = input
        do_send(INPUTS[input], {:timeout => 20000, :name => :input, :delay => 2000})    # does an auto adjust on switch to vga
        #video_input(0)    # high level command
        self[:input] = input
        brightness_status(60)        # higher status than polling commands - lower than input switching (vid then audio is common)
        contrast_status(60)

        logger.debug "-- Sharp LCD, requested to switch to: #{input}"
    end

    AUDIO = {
        :audio1 => 'ASDP   2',
        :audio2 => 'ASDP   3',
        :dvi => 'ASDP   1',
        :dvi_alt => 'ASDA   1',
        :hdmi => 'ASHP   0',
        :hdmi_3mm => 'ASHP   1',
        :hdmi_rca => 'ASHP   2',
        :vga => 'ASAP   1',
        :component => 'ASCA   1'
    }
    def switch_audio(input)
        input = input.to_sym if input.class == String
        self[:audio] = input

        do_send(AUDIO[input], :name => :audio)
        mute_status(0)        # higher status than polling commands - lower than input switching
        #volume_status(60)    # Mute response requests volume

        logger.debug "-- Sharp LCD, requested to switch audio to: #{input}"
    end


    #
    # Auto adjust
    #
    def auto_adjust
        do_send('AGIN   1', :timeout => 20000)
    end


    #
    # Value based set parameter
    #
    def brightness(val)
        val = 31 if val > 31
        val = 0 if val < 0

        message = "VLMP"
        message += val.to_s.rjust(4, ' ')

        do_send(message)
    end

    def contrast(val)
        val = 60 if val > 60
        val = 0 if val < 0

        val = val * 2 if self[:input] == :vga        # See sharp Manual

        message = "CONT"
        message += val.to_s.rjust(4, ' ')

        do_send(message)
    end

    def volume(val)
        val = 31 if val > 31
        val = 0 if val < 0

        message = "VOLM"
        message += val.to_s.rjust(4, ' ')

        do_send(message)

        self[:audio_mute] = false    # audio is unmuted when the volume is set (TODO:: check this)
    end

    def mute
        do_send('MUTE   1')
        mute_status(50)    # High priority mute status

        logger.debug "-- Sharp LCD, requested to mute audio"
    end

    def unmute
        do_send('MUTE   0')
        mute_status(50)    # High priority mute status

        logger.debug "-- Sharp LCD, requested to unmute audio"
    end


    #
    # LCD Response code
    #
    def received(data, resolve, command)        # Data is default received as a string
        logger.debug "-- Sharp LCD, received: #{data}"

        value = nil

        if data == "Password:OK"
            do_poll
        elsif data == "Password:Login incorrect"
            logger.info "Sharp LCD, bad login or logged off. Attempting login.."
            schedule.in('5s') do
                send_credentials
            end
            return true
        elsif data == "OK"
            return true
        elsif data == "WAIT"
            logger.debug "-- Sharp LCD, wait"
            return nil
        elsif data == "ERR"
            logger.debug "-- Sharp LCD, error"
            return false
        end

        if command.nil?
            if data.length < 8        # Out of order send?
                logger.info "Sharp sent out of order response: #{data}"
                return :fail        # this will be ignored
            end
            command = data[0..3].to_sym
            value = data[4..7].to_i
        else
            value = data.to_i
            command = command[:value_ret_only] || command[:name]
            logger.debug "setting value ret: #{command}"
        end

        case command
            when :POWR # Power status
                self[:warming] = false
                self[:power] = value > 0
            when :INPS # Input status
                self[:input] = INPUTS[value]
                logger.debug "-- Sharp LCD, input #{INPUTS[value]} == #{value}"
            when :VOLM # Volume status
                if not self[:audio_mute]
                    self[:volume] = value
                end
            when :MUTE # Mute status
                self[:audio_mute] = value == 1
                if(value == 1)
                    self[:volume] = 0
                else
                    volume_status(90)    # high priority
                end
            when :CONT # Contrast status
                value = value / 2 if self[:input] == :vga
                self[:contrast] = value
            when :VLMP # brightness status
                self[:brightness] = value
            when :PWOD
                self[:power_on_delay] = value
        end

        return true # Command success?
    end


    def do_poll
        power_state? do
            result = self[:power]

            if result == On
                power_on_delay
                #video_input
                #audio_input
                mute_status
                brightness_status
                contrast_status
            end
        end
    end


    private


    def send_credentials
        do_send(setting(:username) || '',  { delay: 500, wait: false, priority: 100 })
        do_send((setting(:password) || ''), { delay_on_receive: 1000, priority: 100 })
    end


    OPERATION_CODE = {
        :video_input => 'INPS????',
        #:audio_input => 'ASDP????',    # This would have to be a regular function (too many return values and polling values)
        :volume_status => 'VOLM????',
        :mute_status => 'MUTE????',
        :power_on_delay => 'PWOD????',
        :contrast_status => 'CONT????',
        :brightness_status => 'VLMP????',
    }
    #
    # Automatically creates a callable function for each command
    #    http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
    #    http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
    #
    OPERATION_CODE.each_pair do |command, value|
        define_method command do |*args|
            priority = 0
            if args.length > 0
                priority = args[0]
            end
            logger.debug "Sharp sending: #{command}"
            do_send(value.clone, {:priority => priority, :value_ret_only => value[0..3].to_sym})    # Status polling is a low priority
        end
    end


    #
    # Builds the command and creates the checksum
    #
    def do_send(command, options = {})
        #logger.debug "-- Sharp LCD, sending: #{command}"

        command = command.clone
        command << 0x0D << 0x0A

        send(command, options)
    end
end

