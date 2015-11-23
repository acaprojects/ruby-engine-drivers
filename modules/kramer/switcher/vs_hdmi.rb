module Kramer; end
module Kramer::Switcher; end


# :title:Kramer video switches
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
#
# video1 => input
# video2
# video3
#

#
# NOTE:: These devices should be marked as make and break!
#

class Kramer::Switcher::VsHdmi
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    tcp_port 23
    descriptive_name 'Kramer Protocol 2000 Switcher'
    generic_name :Switcher

    # Communication settings
    delay between_sends: 150
    wait_response false

    # We wait 5 seconds before the connection is broken (make and break)
    inactivity_timeout 5000

    
    def on_load
        
        #
        # Setup constants
        #
        self[:limits_known] = false
    end
    
    def connected
        #
        # Get current state of the switcher
        #
        get_machine_type
    end

    
    COMMANDS = {
        :reset_video => 0,
        :switch_video => 1,
        :status_video => 5,
        :define_machine => 62,
        :identify_machine => 61
    }
    
    
    #
    # Starting at input 1
    #
    def switch(map)
                # instr, inp,  outp, machine number
                # Switch video
        command = [1, 0x80, 0x80, 0xFF]
        
        map.each do |input, outputs|
            outputs = [outputs] unless outputs.class == Array
            input = input.to_s if input.class == Symbol
            input = input.to_i if input.class == String
            outputs.each do |output|
                command[1] = 0x80 + input
                command[2] = 0x80 + output
                outname = :"video#{output}"
                send(command, name: outname)
                self[outname] = input
            end
        end
    end
    alias :switch_video :switch
    
    def received(data, resolve, command)
        logger.debug "Kramer sent 0x#{byte_to_hex(data)}"
        
        data = str_to_array(data)
        
        return nil if data[0] & 0b1000000 == 0    # Check we are the destination

        data[1] = data[1] & 0b1111111    # input
        data[2] = data[2] & 0b1111111    # output

        case data[0] & 0b111111
        when COMMANDS[:define_machine]
            if data[1] == 1
                self[:video_inputs] = data[2]
            elsif data[1] == 2
                self[:video_outputs] = data[2]
            end
            self[:limits_known] = true    # Set here in case unsupported
        when COMMANDS[:status_video]
            if data[2] == 0 # Then data[1] has been applied to all the outputs
                logger.debug "Kramer switched #{data[1]} -> All"
                
                (1..self[:video_outputs]).each do |i|
                    self["video#{i}"] = data[1]
                end
            else
                self["video#{data[2]}"] = data[1]
                
                logger.debug "Kramer switched #{data[1]} -> #{data[2]}"
                
                #
                # As we may not know the max number of inputs if get machine type didn't work
                #
                self[:video_inputs] = data[1] if data[1] > self[:video_inputs]
                self[:video_outputs] = data[2] if data[2] > self[:video_outputs]
            end
        when COMMANDS[:identify_machine]
            logger.debug "Kramer switcher protocol #{data[1]}.#{data[2]}"
        end
        
        return :success
    end
    
    
    private
    

    #
    # No all switchers implement this
    #
    def get_machine_type
                # id com,    video
        command = [62, 0x81, 0x81, 0xFF]
        send(command, name: :inputs)    # num inputs
        command[1] = 0x82
        send(command, name: :outputs)    # num outputs
    end
end
