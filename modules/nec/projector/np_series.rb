module Nec; end
module Nec::Projector; end


# :title:All NEC Control Module (default port - )
#
# Controls all NEC projectors as of 9/01/2011
# Status information avaliable:
# -----------------------------
#
# (built in)
# connected
#
# (module defined)
# error (array of strings)
#
# lamp_status
# lamp_target
# lamp_warming
# lamp_cooling
# lamp_usage (array of integers representing hours)
# filter_usage
#
# volume
# volume_min == 0
# volume_max == 63
#
# zoom
# zoom_min
# zoom_max
# 
# mute (picture and audio)
# picture_mute
# audio_mute
# onscreen_mute
# picture_freeze
# 
# target_input
# input_selected
# 
# model_name
# model_series
#
#


class Nec::Projector::NpSeries
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 7142
    descriptive_name 'NEC Projector'
    generic_name :Display

    # Communication settings
    delay between_sends: 100


    def on_unload
    end
    
    def on_update
        self[:power_stable] = true
        self[:input_stable] = true

        self[:volume_min] = setting(:volume_min) || 0
        self[:volume_max] = setting(:volume_max) || 63
    end
    
    

    #
    # Sets up any constants 
    #
    def on_load
        #
        # Setup constants
        #
        self[:error] = []
        
        on_update
    end

    #
    # Connect and request projector status
    #    NOTE:: Only connected and disconnected are threadsafe
    #        Access of other variables should be protected outside of these functions
    #
    def connected
        #
        # Get current state of the projector
        #
        do_poll

        #
        # Get the state every 50 seconds :)
        #
        @polling_timer = schedule.every('50s') do
            do_poll
        end
    end

    def disconnected
        #
        # Perform any cleanup functions here
        #
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil

        # Disconnect often occurs on power off
        # We may have not received a status response before the disconnect occurs
        self[:power] = false
    end


    #
    # Command Listing
    #    Second byte used to detect command type
    #
    COMMAND = {
        # Mute controls
        :mute_picture =>    "$02,$10,$00,$00,$00,$12",
        :unmute_picture =>    "$02,$11,$00,$00,$00,$13",
        :mute_audio_cmd =>  "02H 12H 00H 00H 00H 14H",
        :unmute_audio =>    "02H 13H 00H 00H 00H 15H",
        :mute_onscreen =>    "02H 14H 00H 00H 00H 16H",
        :unmute_onscreen =>    "02H 15H 00H 00H 00H 17H",

        :freeze_picture =>    "$01,$98,$00,$00,$01,$01,$9B",
        :unfreeze_picture =>"$01,$98,$00,$00,$01,$02,$9C",

        :status_lamp =>        "00H 81H 00H 00H 00H 81H",        # Running sense (ret 81)
        :status_input =>    "$00,$85,$00,$00,$01,$02,$88",    # Input status (ret 85)
        :status_mute =>        "00H 85H 00H 00H 01H 03H 89H",    # MUTE STATUS REQUEST (Check 10H on byte 5)
        :status_error =>    "00H 88H 00H 00H 00H 88H",        # ERROR STATUS REQUEST (ret 88)
        :status_model =>    "00H 85H 00H 00H 01H 04H 8A",    # request model name (both of these are related)

        # lamp hours / remaining information
        :lamp_information =>   "03H 8AH 00H 00H 00H 8DH",        # LAMP INFORMATION REQUEST
        :filter_information => "03H 8AH 00H 00H 00H 8DH",
        :projector_information => "03H 8AH 00H 00H 00H 8DH",

        :background_black =>"$03,$B1,$00,$00,$02,$0B,$01,$C2",    # set mute to be a black screen
        :background_blue => "$03,$B1,$00,$00,$02,$0B,$00,$C1",    # set mute to be a blue screen
        :background_logo => "$03,$B1,$00,$00,$02,$0B,$02,$C3"    # set mute to be the company logo
    }


    #
    # Automatically creates a callable function for each command
    #    http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
    #    http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
    #
    COMMAND.each_key do |command|
        define_method command do |opts = {}|
            opts[:hex_string] = true
            opts[:name] = command
            send(COMMAND[command], opts)
        end
    end


    #
    # Volume Modification
    #
    def volume(vol)
        #         volume base command              D1    D2    D3    D4    D5 + CKS
        command = [0x03, 0x10, 0x00, 0x00, 0x05, 0x05, 0x00, 0x00, 0x00, 0x00]
        # D3 = 00 (absolute vol) or 01 (relative vol)
        # D4 = value (lower bits 0 to 63)
        # D5 = value (higher bits always 00h)

        vol = 63 if vol > self[:volume_max]
        vol = 0 if vol < self[:volume_min]
        command[-2] = vol

        self[:volume] = vol

        send_checksum(command)
    end

    #
    # Mutes everything
    #
    def mute(state = true)
        if state
            mute_picture
            mute_onscreen
        else
            unmute
        end
    end

    #
    # unmutes everything desirable
    #
    def unmute
        unmute_picture
    end

    # Support naitive Audio Mute
    def mute_audio(mute = true)
        if mute
            mute_audio_cmd
        else
            unmute_audio
        end
    end

    
    AUDIO = {
        hdmi: 0,
        vga: 1
    }

    # Switches HDMI audio
    def switch_audio(input)
        # C0 == HDMI Audio
        command = [0x03, 0xB1, 0x00, 0x00, 0x02, 0xC0]
        command << AUDIO[input.to_sym]
        send_checksum(command, name: :switch_audio)
    end

    #
    # Sets the lamp power value
    #
    def power(power)
        #:lamp_on =>        "$02,$00,$00,$00,$00,$02",
        #:lamp_off =>        "$02,$01,$00,$00,$00,$03",
        self[:power_stable] = false

        command = [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
        if is_negatory?(power)
            command[1] += 1        # power off
            command[-1] += 1    # checksum
            self[:power_target] = Off

            # Jump ahead of any other queued commands as they are no longer important
            send(command, {
                :name => :power,
                :timeout => 60000,  # don't want retries occuring very fast
                :delay => 30000,
                :clear_queue => true,
                :priority => 100,
                :delay_on_receive => 200  # give it a little bit of breathing room
            })
        else
            self[:power_target] = On
            send(command, :name => :power, :timeout => 15000, :delay => 1000)
        end
    end
    
    def power?(options = {}, &block)
        options[:emit] = block if block_given?
        options[:hex_string] = true
        send(COMMAND[:status_lamp], options)
    end


    INPUTS = {
        :vga1 =>        0x01,
        :vga =>            0x01,
        :rgbhv =>        0x02,    # \
        :dvi_a =>        0x02,    #  } - all of these are the same
        :vga2 =>        0x02,    # /

        :composite =>    0x06,
        :svideo =>        0x0B,

        :component1 =>    0x10,
        :component =>    0x10,
        :component2 =>    0x11,

        :hdmi =>        0x1A,    # \
        :dvi =>            0x1A,    # | - These are the same
        :hdmi2 =>        0x1B,
        :display_port => 0xA6,

        :lan =>            0x20,
        :viewer =>        0x1F
    }
    def switch_to(input)
        input = input.to_sym if input.class == String

        #
        # Input status update
        #    As much for internal use as external
        #    and with the added benefit of being thread safe
        #
        self[:target_input] = input        # should do this for power on and off (ensures correct state)
        self[:input_stable] = false

        command = [0x02, 0x03, 0x00, 0x00, 0x02, 0x01]
        command << INPUTS[input]
        send_checksum(command, :name => :input)
    end


    #
    # Return true if command success, nil if still waiting, false if fail
    #
    def received(data, resolve, command)
        response = data
        data = str_to_array(data)
        req = str_to_array(command[:data]) if command && command[:data]
        
        logger.debug { "NEC projector sent: 0x#{byte_to_hex(response)}" }
        
        #
        # Command failed
        #
        if data[0] & 0xA0 == 0xA0
            #
            # We were changing power state at time of failure we should keep trying
            #
            if req && [0x00, 0x01].include?(req[1])
                command[:delay_on_receive] = 6000
                power?
                return true
            end
            logger.warn "-- NEC projector, sent fail code for command: 0x#{byte_to_hex(req)}" if req
            logger.warn "-- NEC projector, response was: 0x#{byte_to_hex(response)}"
            return false
        end

        #
        # Check checksum
        #
        if !check_checksum(data)
            logger.warn "-- NEC projector, checksum failed for command: 0x#{byte_to_hex(req)}" if req
            return false
        end

        #
        # Process a successful command
        #    add 0x20 to the first byte of the send command
        #    Then match the second byte to the second byte of the send command
        #
        case data[0]
        when 0x20
            case data[1]
                when 0x81
                    process_power_status(data, command)
                    return true
                when 0x88
                    process_error_status(data, command)
                    return true
                when 0x85
                    # Return if we can't work out what was requested initially
                    return true unless req

                    case req[-2]
                        when 0x02
                            return process_input_state(data, command)
                        when 0x03
                            process_mute_state(data, req)
                            return true
                    end
            end
        when 0x22
            case data[1]
                when 0x03
                    return process_input_switch(data, req)
                when 0x00, 0x01
                    process_lamp_command(data, req)
                    return true
                when 0x10, 0x11, 0x12, 0x13, 0x14, 0x15
                    status_mute    # update mute status's (dry)
                    return true
            end
        when 0x23
            case data[1]
                when 0x10
                    #
                    # Picture, Volume, Keystone, Image adjust mode
                    #    how to play this?
                    #    
                    #    TODO:: process volume control
                    #
                    return true
                when 0x8A
                    process_projector_information(data, req)
                    return true

                when 0xB1
                    # This is the audio switch command
                    # TODO:: data[-2] == 0:Normal, 1:Error
                    # If error do we retry? Or does it mean something else
                    return true 
            end
        end

        logger.info "-- NEC projector, no status updates defined for response: #{byte_to_hex(response)}"
        logger.info "-- NEC projector, command was: 0x#{byte_to_hex(req)}" if req
        return true                                            # to prevent retries on commands we were not expecting
    end


    private    # All response handling functions should be private so they cannot be called from the outside world


    #
    # The polling routine for the projector
    #
    def do_poll
        power?({:priority => 0}) do
            if self[:power]
                status_input(priority: 0)
                status_mute(priority: 0)
                background_black(priority: 0)
                lamp_information(priority: 0)
            end
        end
        #projector_information
        #status_error
    end


    #
    # Process the lamp on/off command response
    #
    def process_lamp_command(data, req)
        logger.debug "-- NEC projector sent a response to a power command".freeze

        #
        # Ensure a change of power state was the last command sent
        #
        #self[:power] = data[1] == 0x00
        if req.present? && [0x00, 0x01].include?(req[1])
            power?    # Queues the status power command
        end
    end

    #
    # Process the lamp status response
    #    Intimately entwinded with the power power command
    #    (as we need to control ensure we are in the correct target state)
    #
    def process_power_status(data, command)
        logger.debug "-- NEC projector sent a response to a power status command".freeze

        self[:power] = (data[-2] & 0b10) > 0x0    # Power on?

        if (data[-2] & 0b100000) > 0 || (data[-2] & 0b10000000) > 0
            # Projector cooling || power on off processing

            if self[:power_target] == On
                self[:cooling] = false
                self[:warming] = true

                logger.debug "power warming...".freeze


            elsif self[:power_target] == Off
                self[:warming] = false
                self[:cooling] = true

                logger.debug "power cooling...".freeze
            end
            
            
            # recheck in 3 seconds
            schedule.in(3000) do
                power?
            end

            #    Signal processing
        elsif (data[-2] & 0b1000000) > 0
            schedule.in(3000) do
                power?
            end
        else
            #
            # We are in a stable state!
            #
            if (self[:power] != self[:power_target]) && !self[:power_stable]
                if self[:power_target].nil?
                    self[:power_target] = self[:power]    # setup initial state if the control system is just coming online
                    self[:power_stable] = true
                else
                    #
                    # if we are in an undesirable state then correct it
                    #
                    logger.debug "NEC projector in an undesirable power state... (Correcting)".freeze
                    power(self[:power_target])
                end
            else
                logger.debug "NEC projector is in a good power state...".freeze

                self[:warming] = false
                self[:cooling] = false
                self[:power_stable] = true

                #
                # Ensure the input is in the correct state unless the lamp is off
                #
                status_input unless self[:power] == Off     # calls status mute
            end
        end


        logger.debug { "Current state {power: #{self[:power]}, warming: #{self[:warming]}, cooling: #{self[:cooling]}}" }
    end


    #
    # NEC has different values for the input status when compared to input selection
    #
    INPUT_MAP = {
        0x01 => {
            0x01 => [:vga, :vga1],
            0x02 => [:composite],
            0x03 => [:svideo],
            0x06 => [:hdmi, :dvi],
            0x07 => [:viewer],
            0x21 => [:hdmi],
            0x22 => [:display_port]
        },
        0x02 => {
            0x01 => [:vga2, :dvi_a, :rgbhv],
            0x04 => [:component2],
            0x06 => [:display_port, :hdmi2],
            0x07 => [:lan],
            0x21 => [:hdmi2]
        },
        0x03 => {
            0x04 => [:component, :component1]
        }
    }
    def process_input_state(data, command)
        logger.debug "-- NEC projector sent a response to an input state command".freeze


        return if self[:power] == Off        # no point doing anything here if the projector is off
        first = INPUT_MAP[data[-15]]
        return :ignore unless first

        self[:input_selected] = first[data[-14]] || [:unknown]
        self[:input] = self[:input_selected][0]
        if data[-17] == 0x01
            command[:delay_on_receive] = 3000        # still processing signal
            status_input
        else
            status_mute                            # get mute status one signal has settled
        end

        logger.debug { "The input selected was: #{self[:input_selected][0]}" }

        #
        # Notify of bad input selection for debugging
        #    We ensure at the very least power state and input are always correct
        #
        if !self[:input_selected].include?(self[:target_input]) && !self[:input_stable]
            if self[:target_input].nil?
                self[:target_input] = self[:input_selected][0]
                self[:input_stable] = true
            else
                switch_to(self[:target_input])
                logger.debug { "-- NEC input state may not be correct, desired: #{self[:target_input]} current: #{self[:input_selected]}" }
            end
        else
            self[:input_stable] = true
        end

        true
    end


    #
    # Check the input switching command was successful
    #
    def process_input_switch(data, req)
        logger.debug "-- NEC projector responded to switch input command".freeze   

        if data[-2] != 0xFF
            status_input    # Double check with a status update
            return true
        end

        logger.debug { "-- NEC projector failed to switch input with command: #{byte_to_hex(req)}" }
        return false    # retry the command
    end


    #
    # Process the mute state response
    #
    def process_mute_state(data, command)
        logger.debug "-- NEC projector responded to mute state command".freeze

        self[:picture_mute] = data[-17] == 0x01
        self[:audio_mute] = data[-16] == 0x01
        self[:onscreen_mute] = data[-15] == 0x01

        #if !self[:onscreen_mute] && self[:power]
            #
            # Always mute onscreen
            #
        #    mute_onscreen
        #end

        self[:mute] = data[-17] == 0x01    # Same as picture mute
    end


    #
    # Process projector information response
    #    lamp1 hours + filter hours
    #
    def process_projector_information(data, command)
        logger.debug "-- NEC projector sent a response to a projector information command".freeze

        lamp = 0
        filter = 0    

        #
        # get lamp usage
        #
        shift = 0
        data[87..90].each do |byte|
            lamp += byte << shift
            shift += 8
        end

        #
        # get filter usage
        #
        shift = 0
        data[91..94].each do |byte|
            filter += byte << shift
            shift += 8
        end

        self[:lamp_usage] = lamp / 3600    # Lamp usage in hours
        self[:filter_usage] = filter / 3600
    end


    #
    # provide all the error information required
    #
    ERROR_CODES = [{
        0b1 => "Lamp cover error",
        0b10 => "Temperature error (Bimetal)",
        #0b100 == not used
        0b1000 => "Fan Error",
        0b10000 => "Fan Error",
        0b100000 => "Power Error",
        0b1000000 => "Lamp Error",
        0b10000000 => "Lamp has reached its end of life"
    }, {
        0b1 => "Lamp has been used beyond its limit",
        0b10 => "Formatter error",
        0b100 => "Lamp no.2 Error"
    }, {
        #0b1 => "not used",
        0b10 => "FPGA error",
        0b100 => "Temperature error (Sensor)",
        0b1000 => "Lamp housing error",
        0b10000 => "Lamp data error",
        0b100000 => "Mirror cover error",
        0b1000000 => "Lamp no.2 has reached its end of life",
        0b10000000 => "Lamp no.2 has been used beyond its limit"
    }, {
        0b1 => "Lamp no.2 housing error",
        0b10 => "Lamp no.2 data error",
        0b100 => "High temperature due to dust pile-up",
        0b1000 => "A foreign object sensor error"
    }]
    def process_error_status(data, command)
        logger.debug "-- NEC projector sent a response to an error status command".freeze

        errors = []
        error = data[5..8]
        error.each_index do |byte_no|
            if error[byte_no] > 0                            # run throught each byte
                ERROR_CODES[byte_no].each_key do |key|        # if error indicated run though each key
                    if (key & error[byte_no]) > 0            # check individual bits
                        errors << ERROR_CODES[byte_no][key]    # add errors to the error list
                    end
                end
            end
        end
        self[:error] = errors
    end


    #
    # For commands that require a checksum (volume, zoom)
    #
    def send_checksum(command, options = {})
        #
        # Prepare command for sending
        #
        command = str_to_array(hex_to_byte(command)) unless command.is_a?(Array)
        check = 0
        command.each do |byte|    # Loop through the first to second last element
            check = (check + byte) & 0xFF
        end
        command << check
        send(command, options)
    end

    def check_checksum(data)
        check = 0
        data[0..-2].each do |byte|    # Loop through the first to second last element
            check = (check + byte) & 0xFF
        end
        return check == data[-1]    # Check the check sum equals the last element
    end
end

