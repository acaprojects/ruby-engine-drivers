# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'set'

module Lightware; end
module Lightware::Switcher; end

# Documentation: https://aca.im/driver_docs/Lightware/lightware%20protocol%20(MX-FR%20series).pdf

class Lightware::Switcher::LightwareProtocol
    include ::Orchestrator::Constants


    # Discovery Information
    # NOTE:: The V3 protocol runs on port 6107
    tcp_port 10001
    descriptive_name 'Lightware Switcher'
    generic_name :Switcher

    # Communication settings
    # This will strip the brackets from the response data
    tokenize indicator: '(', delimiter: ")\r\n"


    def on_load
        on_update
    end

    def on_update
        @ignore_outs = Set.new(Array(setting(:force_available)))
    end

    def connected
        set_lightware_protocol
        routing_state?(priority: 0)
        mute_state?(priority: 0)

        schedule.every('30s') do
            logger.debug "Maintaining Connection"

            # Low priority poll to maintain connection
            routing_state?(priority: 0)
            mute_state?(priority: 0)
            output_status?(priority: 0)
            input_status?(priority: 0)
        end
    end

    def disconnected
        #
        # Disconnected may be called without calling connected
        #    Hence the check if timer is nil here
        #
        schedule.clear
    end

    # MX-FR80R only
    #def power(state)
    #    if is_affirmative?(state)
    #        send("{PWR_ON}\r\n")
    #    else
    #        send("{PWR_OFF}\r\n")
    #    end
    #end

    #
    # No need to wait as commands can be chained
    #
    def switch(map)
        command = String.new

        map.each do |input, outputs|
            input = input.to_s if input.is_a?(Symbol)
            input = input.to_i if input.is_a?(String)

            outputs = Array(outputs)
            outputs.each do |output|
                command << "{#{input}@#{output}}"
            end
        end

        command << "\r\n"
        send(command)
    end

    def switch_video(map)
        switch map
    end

    def switch_audio(map)
        switch map
    end
    
    def routing_state?(**options)
        send("{VC}\r\n", options)
    end

    def mute_state?(**options)
        send("{VM}\r\n", options)
    end

    def serial_number?
        send("{s}\r\n")
    end

    def firmware_version?
        send("{f}\r\n")
    end


    def mute_video(outputs)
        outputs = Array(outputs)
        command = String.new
        outputs.each do |output|
            command << "{##{output}}"
        end
        command << "\r\n"
        send(command)
    end

    def unmute_video(outputs)
        outputs = Array(outputs)
        command = String.new
        outputs.each do |output|
            command << "{+#{output}}"
        end
        command << "\r\n"
        send(command)
    end

    def set_preset(number)
        send("{$#{number}}\r\n")
    end

    def recall_preset(number)
        send("{%#{number}}\r\n")
    end

    def input_status?(**options)
        send("{:ISD}\r\n", options)
    end

    def output_status?(**options)
        send("{:OSD}\r\n", options)
    end


    protected


    def set_lightware_protocol
        # High priority as should run before any commands are sent
        send("{P_1}\r\n", priority: 100)
    end


    TrackErrors = ['W', 'M', 'E', 'F']
    RespErrors = {
        1 => 'input number exceeds the maximum number of inputs or equals zero',
        2 => 'output number exceeds the installed number of outputs or equals zero',
        3 => 'value exceeds the maximum allowed value can be sent',
        4 => 'preset number exceeds the maximum allowed preset number'
    }
    def received(data, resolve, command)
        logger.debug { "Matrix sent #{data}" }

        if data[0..2] == 'ERR'
            logger.debug {
                err = String.new("Matrix sent error #{data}: ")
                err << (RespErrors[data[3..-1].to_i] || 'unknown error code')
                err << "\nfor command #{command[:data]}" if command
                err
            }
            return :success
        end

        case data[0]
        when 'I'
            # ISD (input port status)
            # ISD 777773333777077077377771700000007777777777777777777770000000000000000000000000000
            data[4..-1].each_char.to_a.each_with_index do |char, index|
                self["videoIn#{index + 1}"] = char != '0'
            end
        when 'O'
            if data[0..2] == 'OSD'
                # OSD (output port status)
                # OSD 111111111111110011111111111100000000000000000000000000000000000000000000000000000
                data[4..-1].each_char.to_a.each_with_index do |char, index|
                    out = index + 1
                    if @ignore_outs.include? out
                        self["videoOut#{out}"] = true
                    else
                        self["videoOut#{out}"] = char != '0'
                    end
                end
            else
                # Probably a switch command
                # Returns: O02 I11
                outp, inp = data.split(' ')
                self["video#{outp[1..-1].to_i}"] = inp[1..-1].to_i
            end
        when 'E'
            # Probably Error List
            num, level, code, param, times = data.split(' ')
            if TrackErrors.include? level[0]
                self[level] = [code, param, times]
            end
        when 'A'
            # Probably the all outputs command
            # Returns: ALL O12 O45 O01 ...
            outputs = data.split(' ')
            outputs.shift
            self[:num_outputs] = outputs.length
            outputs.each_with_index do |input, output|
                self["video#{output + 1}"] = input.to_i
            end
        when 'M'
            # Probably the all mutes command
            # Returns: MUT 1 0 0 1 0 0 ...
            outputs = data.split(' ')
            outputs.shift
            outputs.each_index do |out|
                self["video#{out}_muted"] = outputs[out] == '1'
            end
        when '1', '0'
            # Probably the mute response
            # Returns 1MT01, 0MT13
            if data[1] == 'M'
                self["video#{data[3..-1]}_muted"] = data[0] == '1'
            end
        when 'L'
            # Probably Load Preset response
            # Returns: LPR01
            self[:last_preset] = data[3..-1].to_i
        when 'S'
            # Probably the serial number
            # Returns: SN:11270142
            self[:serial_number] = data[3..-1]
        when 'F'
            # Probably the firmware version
            # Returns: FW:3.3.1r
            self[:firmware] = data[3..-1]
        end

        return :success
    end
end

