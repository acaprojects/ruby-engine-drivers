module Aca; end
module Aca::Crestron; end


class Aca::Crestron::DmSwitcherInterface
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Default discovery information
    tcp_port 8400
    descriptive_name 'Crestron DM Series Switcher'
    generic_name :Switcher

    # Communication settings
    tokenize delimiter: "\xFF"
    delay between_sends: 500
    wait_response false


    # initialize will not have access to settings
    def on_load
        # Outputs (1 == switch)
        @outputs = [1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0xFF]
        @audio = [2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0xFF]
    end
    
    def connected
        send("status\xff", wait: true)

        # Maintain connection
        @polling_timer = schedule.every('61s') do
            logger.debug "-- Polling Crestron"
            send("status\xff", wait: true)
        end
    end
    
    def disconnected
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end


    TYPE = {
        0x01 => :video,
        0x02 => :audio,
        :video => 0x01,
        :audio => 0x02
    }

    
    def switch(map)
        # Update output mappings
        map.each do |input, outputs|
            outputs = [outputs] unless outputs.class == Array
            input = input.to_s if input.class == Symbol
            input = input.to_i if input.class == String
            outputs.each do |output|
                output = output.to_i

                if output < 17
                    @outputs[output] = input
                    self["video#{output}"] = input
                else
                    # outputs above 16 are considered audio
                    audioOut = output - 16
                    @audio[audioOut] = input
                    self["audio#{audioOut}"] = input
                end
            end
        end

        # Perform the video switch
        @outputs[0] = TYPE[:video]     # video switch command
        @outputs[17] = 0xff         # ff == delimiter
        send(@outputs[0..17])         # ensure correct command length

        # Perform the audio switch
        @audio[0] = TYPE[:audio]     # audio switch command
        @audio[17] = 0xff             # ff == delimiter
        send(@audio[0..17])         # ensure correct command length
    end
    alias :switch_video :switch


    protected


    def received(data, resolve, command)
        logger.debug "-- Crestron sent: #{data}"

        response = str_to_array(data)
        case TYPE[response[0]]
        when :video
            @outputs = response
            @outputs.each_index do |i|
                if i > 0 && i < 17
                    self["video#{i}"] = @outputs[i]
                end
            end
            @outputs << 0xFF # as the buffering process would have removed this
        when :audio
            @audio = response
            @audio.each_index do |i|
                if i > 0 && i < 17
                    self["audio#{i}"] = @audio[i]
                end
            end
            @audio << 0xFF # as the buffering process would have removed this
        end

        :success
    end
end

