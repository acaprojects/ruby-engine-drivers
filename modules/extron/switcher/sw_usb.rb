load File.expand_path('../base.rb', File.dirname(__FILE__))
module Extron::Switcher; end


# :title:Extron USB Switcher
#
# Status information avaliable:
# -----------------------------
#
# (built in)
# connected
#
# (module defined)
# input



class Extron::Switcher::SwUsb < Extron::Base

    def switch(input = nil)
        send("#{input}!")
    end


    def received(data, resolve, command)
        logger.debug { "Extron Matrix sent #{data}" }

        if data =~ /Login/i
            device_ready
        else
            case data[0..2].to_sym
            when :Chn    # Audio mute
                self[:input] = data = data[3].to_i
            else
                if data[0] == 'E'
                    logger.info "Extron Error #{ERRORS[data[1..2].to_i]}"
                    logger.info "- for command #{command[:data]}" unless command.nil?
                    return :failed
                end
            end
        end

        return :success
    end


    private


    ERRORS = {
        1 => 'Invalid input number (number is too large)',
        10 => 'Invalid command',
        13 => 'Invalid parameter (number is out of range)'
    }
end

