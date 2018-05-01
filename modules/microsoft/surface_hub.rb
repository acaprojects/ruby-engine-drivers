module Microsoft; end

# Documentation: https://docs.microsoft.com/en-us/surface-hub/use-room-control-system-with-surface-hub

class Microsoft::SurfaceHub
    include ::Orchestrator::Constants

    # Discovery Information
    tcp_port 4999
    descriptive_name 'Microsoft Surface Hub'
    generic_name :Display

    # Communication settings
    tokenize delimiter: "\n"

    def on_load
        self[:power_stable] = true
        on_update
    end
    
    def on_update
    end

    def connected
        power?
        input?
        schedule.every('50s') do
            logger.debug "-- Polling Display"
            power?
            input?
        end
    end

    def disconnected
        schedule.clear
    end

    def power(state, opt = nil)
        self[:power_stable] = false
        self[:power_target] = target = is_affirmative?(state)
        if target
            send "PowerOn\n", name: :power
        else
            send "PowerOff\n", name: :power
        end
    end

    def power?(**options, &block)
        options[:emit] = block if block_given?
        options[:name] = :power_state
        send("Power?\n", options)
    end

    INPUTS = {
        pc: 0,
        display_port: 1,
        hdmi: 2,
        vga: 3
    }
    INPUTS.merge!(INPUTS.invert)

    def switch_to(input)
        input = input.to_sym
        inp = INPUTS[input]
        return unless inp

        # for a responsive UI
        self[:input] = input
        send "Source=#{inp}\n", name: :input
    end

    def input?(**options, &block)
        options[:priority] ||= 0
        options[:name] = :input_status
        options[:emit] ||= block
        send "Source?\n", **options
    end

    def received(data, resolve, command)
        logger.debug { "Hub sent: #{data}" }

        if data.include? 'Error'
            logger.warn data
            return :abort
        end

        resp = data.split('=')
        case resp[0].downcase.to_sym
        when :power
            case resp[1].to_i
            when 0, 2
                self[:power] = Off
            when 1, 5
                self[:power] = On
            end
            if !self[:power_stable]
                if self[:power_target] == self[:power]
                    self[:power_stable] = true
                else
                    power(self[:power_target])
                end
            end
        when :source
            self[:input] = INPUTS[resp[1].to_i] || :unknown
        end

        :success
    end
end
