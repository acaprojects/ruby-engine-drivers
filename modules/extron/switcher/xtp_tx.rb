load File.expand_path('../base.rb', File.dirname(__FILE__))
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

# For control of XTP Transmitters (with input switching), that go back to an input of an XTP Matrix
# Control is via the XTP Matrix
# input  = input of the XTP Matrix that this Tx is connected to
# output = sub-input of the XTP Tx to switch to
# See xtp_tx.png in this folder

class Extron::Switcher::XtpTx < Extron::Base
    descriptive_name 'Extron XTP Transmitter'
    generic_name :Switcher

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
                command += "#{input}*#{output}*3ETIE"
            end
            send("" << 0x1B << command)
            logger.debug { "requesting cmd: #{command}" }
        end
    end


    #
    # Sends copyright information
    # Then sends password prompt
    #
    def received(data, resolve, command)
        logger.debug { "Extron Matrix sent #{data}" }

        if data =~ /Login/i
            device_ready
        elsif command.present? && command[:command] == :information
            data = data.split(' ')
            return :ignore unless data.length > 1
        else
            # ACK looks like 'Etie1*1*3' 'Etiesub_input_vidio*sub_input_audio*3' (but there is no seperation so  video will always ewual audio)
            if data[0-3] == "Etie"    
                input = data[5]   
                sub_input = data[7]
                self["input"] = input
                self["output"] = sub_input
            else
                if data == 'E22'    # Busy! We should retry this one
                    command[:delay_on_receive] = 1 unless command.nil?
                    return :failed

                end

            end
        end

        return :success
    end
end

