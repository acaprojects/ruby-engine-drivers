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



class Extron::Switcher::SwUsbSlow < Extron::Base
    descriptive_name 'Extron USB Slow Switcher'
    generic_name :Switcher

    def switch_to(input = nil)
        do_send("0!", delay: 500)
        do_send("#{input}!")
    end

    def switch(map)
        do_send("0!", delay: 500)
        map.each do |input, outputs|
            do_send("#{input}!")
        end
    end


    def received(data, resolve, command)
        logger.debug { "Extron Matrix sent #{data}" }

        if data =~ /Login/i
            device_ready
        else
            case data[0..2].to_sym
            when :Chn
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

