module Extron; end
module Extron::Mixer; end


# :title:Extron DSP
#
# Status information avaliable:
# -----------------------------
#
# (built in)
# connected
#
# (module defined)
#
#
#
# Volume outputs
# 60000 == volume 1
# 60003 == volume 4
#
# Pre-mix gain inputs
# 40100 == Mic1
# 40105 == Mic6
#


class Extron::Mixer::Dmp64
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    
    def on_load
        #
        # Setup constants
        #
        self[:output_volume_max] = 2168
        self[:output_volume_min] = 1048
        self[:mic_gain_max] = 2298
        self[:mic_gain_min] = 1698

        config({
            :clear_queue_on_disconnect => true    # Clear the queue as we may need to send login
        })
    end

    def connected

    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #    Hence the check if timer is nil here
        #
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end


    def call_preset(number)
        if number < 0 || number > 32
            number = 0    # Current configuration
        end
        send("#{number}.")    # No Carriage return for presents
        # Response: Rpr#{number}
    end

    #
    # Input control
    #
    def adjust_gain(mic, value)    # \e == 0x1B == ESC key
        do_send("\eG4010#{mic}*#{value}AU")
        # Response: DsG4010#{mic}*#{value}
    end

    def adjust_gain_relative(mic, value)    # \e == 0x1B == ESC key
        current = do_send("\eG4010#{mic}AU", :emit => "mic#{mic}_gain")
        do_send("\eG4010#{mic}*#{current + (value * 10)}AU")

        # Response: DsG4010#{mic}*#{value}
    end

    def mute_mic(mic)
        do_send("\eM4000#{mic}*1AU")    # 4000 (input gain), 4010 (pre-mixer gain)
        # Response: DsM4010#{mic}*1
    end

    def unmute_mic(mic)
        do_send("\eM4000#{mic}*0AU")
        # Response: DsM4010#{mic}*0
    end


    #
    # Output control
    #
    def mute(group, value = true, index = nil)
        group = index if index
        val = is_affirmative?(value) ? 1 : 0

        faders = group.is_a?(Array) ? group : [group]
        faders.each do |fad|
            do_send("\eD#{fad}*#{val}GRPM", :group_type => :mute)
        end
        # Response:  GrpmD#{group}*+00001
    end

    def unmute(group, index = nil)
        mute(group, false, index)
        #do_send("\eD#{group}*0GRPM", :group_type => :mute)
        # Response:  GrpmD#{group}*+00000
    end

    def fader(group, value, index = nil)    # \e == 0x1B == ESC key
        faders = group.is_a?(Array) ? group : [group]
        faders.each do |fad|
            do_send("\eD#{fad}*#{value}GRPM", :group_type => :volume)
        end
        
        # Response: GrpmD#{group}*#{value}*GRPM
    end
    
    def fader_status(group, type)
        do_send("\eD#{group}GRPM", :group_type => type)
    end
    
    def fader_relative(group, value)    # \e == 0x1B == ESC key
        if value < 0
            value = -value
            do_send("\eD#{group}*#{value}-GRPM")
        else
            do_send("\eD#{group}*#{value}+GRPM")
        end
        # Response: GrpmD#{group}*#{value}*GRPM
    end


    def response_delimiter
        [0x0D, 0x0A]    # Used to interpret the end of a message
    end

    #
    # Sends copyright information
    # Then sends password prompt
    #
    def received(data, resolve, command)
        logger.debug "Extron DSP sent #{data}"

        if command.nil? && data =~ /Copyright/i
            pass = setting(:password)
            if pass.nil?
                device_ready
            else
                do_send(pass)        # Password set
            end
        elsif data =~ /Login/i
            device_ready
        else
            case data[0..2].to_sym
            when :Grp    # Mute or Volume
                data = data.split('*')
                if command.present? && command[:group_type] == :mute
                    self["ouput#{data[0][5..-1].to_i}_mute"] = data[1][-1] == '1'    # 1 == true
                elsif command.present? && command[:group_type] == :volume
                    self["ouput#{data[0][5..-1].to_i}_volume"] = data[1].to_i
                else
                    return :failed
                end
            when :DsG    # Mic gain
                self["mic#{data[7]}_gain"] = data[9..-1].to_i
            when :DsM    # Mic Mute
                self["mic#{data[7]}_mute"] = data[-1] == '1'    # 1 == true
            when :Rpr    # Preset called
                logger.debug "Extron DSP called preset #{data[3..-1]}"
            else
                if data == 'E22'    # Busy! We should retry this one
                    command[:delay_on_receive] = 1 unless command.nil?
                    return :failed
                elsif data[0] == 'E'
                    logger.info "Extron Error #{ERRORS[data[1..2].to_i]}"
                    logger.info "- for command #{command[:data]}" unless command.nil?
                end
            end
        end

        return :success
    end


    private


    ERRORS = {
        1 => 'Invalid input number (number is too large)',
        12 => 'Invalid port number',
        13 => 'Invalid parameter (number is out of range)',
        14 => 'Not valid for this configuration',
        17 => 'System timed out',
        23 => 'Checksum error (for file uploads)',
        24 => 'Privilege violation',
        25 => 'Device is not present',
        26 => 'Maximum connections exceeded',
        27 => 'Invalid event number',
        28 => 'Bad filename or file not found'
    }


    def device_ready
        do_send("\e3CV")    # Verbose mode and tagged responses
        @polling_timer = schedule.every('2m') do
            logger.debug "-- Extron Maintaining Connection"
            send('Q', :priority => 0)    # Low priority poll to maintain connection
        end
    end




    def do_send(data, options = {})
        send(data << 0x0D, options)
    end
end

