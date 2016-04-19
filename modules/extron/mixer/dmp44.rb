load File.expand_path('../base.rb', File.dirname(__FILE__))
module Extron::Mixer; end


# :title:Extron DSP 44
#
# Status information avaliable:
# -----------------------------
#
# (built in)
# connected
#
# (module defined)
#


class Extron::Mixer::Dmp44 < Extron::Base
    descriptive_name 'Extron DSP DMP44'
    generic_name :Mixer

    def on_load
        super
        
        #
        # Setup constants
        #
        self[:output_volume_max] = 2168
        self[:output_volume_min] = 1048
        self[:mic_gain_max] = 2298
        self[:mic_gain_min] = 1698
    end
    

    def call_preset(number)
        if number < 0 || number > 32
            number = 0    # Current configuration
        end
        send("#{number}.")    # No Carriage return for presents
        # Response: Rpr#{number}
    end
    alias_method :preset, :call_preset

    #
    # Input control
    #
    def adjust_gain(input, value)    # \e == 0x1B == ESC key
        input -= 1
        do_send("\eG3000#{input}*#{value}AU")
        # Response: DsG3000#{input}*#{value}
    end

    def adjust_gain_relative(input, value)    # \e == 0x1B == ESC key
        input -= 1
        current = do_send("\eG3000#{input}AU", :emit => "mic#{input + 1}_gain")
        do_send("\eG3000#{input}*#{current + (value * 10)}AU")

        # Response: DsG3000#{input}*#{value}
    end

    def mute_input(input)
        input -= 1
        do_send("\eM3000#{input}*1AU")
        # Response: DsM3000#{input}*1
    end

    def unmute_input(input)
        input -= 1
        do_send("\eM3000#{input}*0AU")
        # Response: DsM3000#{input}*0
    end


    #
    # Group control
    #
    def mute_group(group)
        do_send("\eD#{group}*1GRPM")
        # Response:  GrpmD#{group}*+00001
    end

    def unmute_group(group)
        do_send("\eD#{group}*0GRPM")
        # Response:  GrpmD#{group}*+00000
    end

    def volume(group, value)    # \e == 0x1B == ESC key
        do_send("\eD#{group}*#{value * 10}*GRPM")
        # Response: GrpmD#{group}*#{value}*GRPM
    end

    def volume_relative(group, value)    # \e == 0x1B == ESC key

        if value < 0
            value = -value
            do_send("\eD#{group}*#{value * 10}-GRPM")
        else
            do_send("\eD#{group}*#{value * 10}+GRPM")
        end
        # Response: GrpmD#{group}*#{value}*GRPM
    end

    #
    # Sends copyright information
    # Then sends password prompt
    #
    def received(data, resolve, command)
        logger.debug { "Extron DSP 44 sent #{data}" }

        if data =~ /Login/i
            device_ready
        else
            cmd = data[0..2].to_sym

            case cmd
            when :Grp    # Mute or Volume
                data = data.split('*')
                if data[1][0] == '+'    # mute
                    self["ouput#{data[0][5..-1].to_i}_mute"] = data[1][-1] == '1'    # 1 == true
                elsif command.present? && command[:group_type] == :volume
                    self["ouput#{data[0][5..-1].to_i}_volume"] = data[1].to_i
                else
                    logger.debug { "DSP response failure as couldn't determine if mute or volume request" }
                    return :ignore
                end
            when :DsG    # Input gain
                self["input#{data[7].to_i + 1}_gain"] = data[9..-1].to_i
            when :DsM    # Input Mute
                self["input#{data[7].to_i + 1}_mute"] = data[-1] == '1'    # 1 == true
            when :Rpr    # Preset called
                logger.debug "Extron DSP called preset #{data[3..-1]}"
            when :Ver
                return :success
            else
                if data == 'E22'    # Busy! We should retry this one
                    command[:delay_on_receive] = 1 unless command.nil?
                    return :failed
                elsif data[0] == 'E'
                    logger.info "Extron Error #{ERRORS[data[1..2].to_i]}"
                    logger.info "- for command #{command[:data]}" unless command.nil?
                else
                    logger.info "unknown response type #{cmd} for response #{data}"
                    logger.info "possibly requested with #{command[:data]}" unless command.nil?
                    return :ignore
                end
            end
        end

        return :success
    end


    private


    ERRORS = {
        10 => 'Invalid command',
        11 => 'Invalid preset',
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
end

