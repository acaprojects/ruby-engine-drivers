module Lightware; end
module Lightware::Switcher; end


# TCP Port: 10001


class Lightware::Switcher::LightwareProtocol
    include ::Orchestrator::Constants


    # This will strip the brackets from the response data
    tokenize indicator: '(', delimiter: ")\r\n"


    def on_load
        on_update
    end

    def on_update
    end

    def connected
        set_lightware_protocol
        routing_state?(priority: 0)
        mute_state?(priority: 0)

        @polling_timer = schedule.every('1m') do
            logger.debug "Maintaining Connection"

            # Low priority poll to maintain connection
            send("{elist=?}\r\n", priority: 0)
            routing_state?(priority: 0)
            mute_state?(priority: 0)
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
        command = ''

        map.each do |input, outputs|
            input = input.to_s if input.is_a?(Symbol)
            input = input.to_i if input.is_a?(String)

            outputs = [outputs] unless outputs.is_a?(Array)
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

    def routing_state?(options = {})
        send("{VC}\r\n", options)
    end

    def mute_state?(options = {})
        send("{VM}\r\n", options)
    end

    def serial_number?
        send("{s}\r\n")
    end

    def firmware_version?
        send("{f}\r\n")
    end


    def mute_video(outputs)
        outputs = [outputs] unless outputs.is_a?(Array)
        command = ''
        outputs.each do |output|
            command << "{##{output}}"
        end
        command << "\r\n"
        send(command)
    end

    def unmute_video(outputs)
        outputs = [outputs] unless outputs.is_a?(Array)
        command = ''
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


    protected


    def set_lightware_protocol
        # High priority as should run before any commands are sent
        send("{P_1}\r\n", priority: 100)
    end


    TrackErrors = ['W', 'M', 'E', 'F']
    def received(data, resolve, command)
        logger.debug { "Matrix sent #{data}" }

        case data[0]
        when 'O'.freeze
            # Probably a switch command
            # Returns: O02 I11
            outp, inp = data.split(' ')
            self["video#{outp[1..-1]}"] = inp[1..-1].to_i
        when 'E'.freeze
            # Probably Error List
            num, level, code, param, times = data.split(' ')
            if TrackErrors.include? level[0]
                self[level] = [code, param, times]
            end
        when 'A'.freeze
            # Probably the all outputs command
            # Returns: ALL O12 O45 O01 ...
            outputs = data.split(' ')
            outputs.shift
            self[:num_outputs] = outputs.length
            outputs.each_index do |out|
                self["video#{out}"] = outputs[out][1..-1].to_i
            end
        when 'M'.freeze
            # Probably the all mutes command
            # Returns: MUT 1 0 0 1 0 0 ...
            outputs = data.split(' ')
            outputs.shift
            outputs.each_index do |out|
                self["video#{out}_muted"] = outputs[out] == '1'.freeze
            end
        when '1'.freeze, '0'.freeze
            # Probably the mute response
            # Returns 1MT01, 0MT13
            if data[1] == 'M'.freeze
                self["video#{data[3..-1]}_muted"] = data[0] == '1'.freeze
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

