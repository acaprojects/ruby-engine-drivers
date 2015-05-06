module Extron; end
module Extron::Switcher; end


# :title:Extron Digital Matrix Switchers
# NOTE:: Very similar to the XTP!! Update both
#
# Status information avaliable:
# -----------------------------
#
# (built in)
# connected
#
# (module defined)
# video_inputs
# video_outputs
# audio_inputs
# audio_outputs
#
# video1 => input (video)
# video2
# video3
# video1_muted => true
#
# audio1 => input
# audio1_muted => true
# 
#
# (Settings)
# password
#


class Extron::Switcher::Dtp
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    def on_load
        #
        # Setup constants
        #
        defaults({
            :wait => false
        })
        config({
            :clear_queue_on_disconnect => true    # Clear the queue as we may need to send login
        })
    end

    def connected
        @polling_timer = schedule.every('2m') do
            logger.debug "-- Extron Maintaining Connection"
            send('Q', :priority => 0)    # Low priority poll to maintain connection
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


    def direct(string)
        send(string, :wait => false)
    end


    #
    # No need to wait as commands can be chained
    #
    def switch(map)
        map.each do |input, outputs|
            input = input.to_s if input.is_a?(Symbol)
            input = input.to_i if input.is_a?(String)

            outputs = [outputs] unless outputs.is_a?(Array)
            command = ''
            outputs.each do |output|
                command += "#{input}*#{output}!"
            end
            send(command)
        end
    end

    def switch_video(map)
        map.each do |input, outputs|
            input = input.to_s if input.is_a?(Symbol)
            input = input.to_i if input.is_a?(String)
            
            
            outputs = [outputs] unless outputs.is_a?(Array)
            command = ''
            outputs.each do |output|
                command += "#{input}*#{output}%"
            end
            send(command)
        end
    end

    def switch_audio(map)
        map.each do |input, outputs|
            input = input.to_s if input.is_a?(Symbol)
            input = input.to_i if input.is_a?(String)
            
            outputs = [outputs] unless outputs.is_a?(Array)
            command = ''
            outputs.each do |output|
                command += "#{input}*#{output}$"
            end
            send(command)
        end
    end

    def mute_video(outputs)
        outputs = [outputs] unless outputs.is_a?(Array)
        command = ''
        outputs.each do |output|
            command += "#{output}*1B"
        end
        send(command)
    end

    def unmute_video(outputs)
        outputs = [outputs] unless outputs.is_a?(Array)
        command = ''
        outputs.each do |output|
            command += "#{output}*0B"
        end
        send(command)
    end

    def mute_audio(outputs)
        outputs = [outputs] unless outputs.is_a?(Array)
        command = ''
        outputs.each do |output|
            command += "#{output}*1Z"
        end
        send(command)
    end

    def unmute_audio(outputs)
        outputs = [outputs] unless outputs.is_a?(Array)
        command = ''
        outputs.each do |output|
            command += "#{output}*0Z"
        end
        send(command)
    end

    def set_preset(number)
        send("#{number},")
    end

    def recall_preset(number)
        send("#{number}.")
    end




    TYPES = {
        analog: 1,
        digital: 2,
        multi: 3
    }
    def configure_audio(input, type = :analog)
        val = TYPES[type]
        send("\x1BI#{input}*#{val}AFMT\r") if val
    end


    # AUDIO Controls
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
    def mute_audio(group, value = true, index = nil)
        group = index if index
        val = is_affirmative?(value) ? 1 : 0

        faders = group.is_a?(Array) ? group : [group]
        faders.each do |fad|
            do_send("\eD#{fad}*#{val}GRPM", :group_type => :mute)
        end
        # Response:  GrpmD#{group}*+00001
    end

    def unmute_audio(group, index = nil)
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




    #
    # Sends copyright information
    # Then sends password prompt
    #
    def received(data, resolve, command)
        logger.debug "Extron Matrix sent #{data}"

        if command.nil? && data =~ /Copyright/i
            pass = setting(:password)
            if pass.nil?
                device_ready
            else
                do_send(pass)        # Password set
            end
        elsif data =~ /Login/i
            device_ready
        elsif command.present? && command[:command] == :information
            data = data.split(' ')
            video = data[0][1..-1].split('X')
            self[:video_inputs] = video[0].to_i
            self[:video_outputs] = video[1].to_i

            audio = data[1][1..-1].split('X')
            self[:audio_inputs] = audio[0].to_i
            self[:audio_outputs] = audio[1].to_i
        else
            case data[0..1].to_sym
            when :Am    # Audio mute
                data = data[3..-1].split('*')
                self["audio#{data[0].to_i}_muted"] = data[1] == '1'
            when :Vm    # Video mute
                data = data[3..-1].split('*')
                self["video#{data[0].to_i}_muted"] = data[1] == '1'
            when :In    # Input to all outputs
                data = data[2..-1].split(' ')
                input = data[0].to_i
                if data[1] =~ /(All|RGB|Vid)/
                    for i in 1..self[:video_outputs]
                        self["video#{i}"] = input
                    end
                end
                if data[1] =~ /(All|Aud)/
                    for i in 1..self[:audio_outputs]
                        self["audio#{i}"] = input
                    end
                end
            when :Ou    # Output x to input y
                data = data[3..-1].split(' ')
                output = data[0].to_i
                input = data[1][2..-1].to_i
                if data[2] =~ /(All|RGB|Vid)/
                    self["video#{output}"] = input
                end
                if data[2] =~ /(All|Aud)/
                    self["audio#{output}"] = input
                end
            else
                if data == 'E22'    # Busy! We should retry this one
                    command[:delay_on_receive] = 1 unless command.nil?
                    return :failed
                end


                # Check for Audio responses
                case data[0..2].to_sym
                when :Grp    # Mute or Volume
                    data = data.split('*')
                    if command.present? && command[:group_type] == :mute
                        self["fader#{data[0][5..-1].to_i}_mute"] = data[1][-1] == '1'    # 1 == true
                    elsif command.present? && command[:group_type] == :volume
                        self["fader#{data[0][5..-1].to_i}"] = data[1].to_i
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
        end

        return :success
    end


    private


    def device_ready
        send("I", :wait => true, :command => :information)
        do_send("\e3CV", :wait => true)    # Verbose mode and tagged responses
    end

    def do_send(data, options = {})
        send(data << 0x0D, options)
    end
end

