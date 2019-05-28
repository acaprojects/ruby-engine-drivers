module Sony; end
module Sony::Display; end

# Documentation: https://docs.google.com/spreadsheets/d/1F8RyaDqLYlKBT7fHJ_PT7yHwH3vVMZue4zUc5McJVYM/edit?usp=sharing

class Sony::Display::CBX
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    tcp_port 4999
    descriptive_name 'Sony CBX Display'
    generic_name :Display

    def on_load
        on_update
    end

    def on_update
    end

    def connected
        schedule.every('60s') { power? }
    end

    def disconnected
        schedule.clear
    end

    #
    # Power commands
    #
    def power(state, opt = nil)
        if is_affirmative?(state)
            send("8C 00 00 02 01 8F", hex_string: true)
            logger.debug "-- sony display requested to power on"
        else
            send("8C 00 00 02 01 8F", hex_string: true)
            logger.debug "-- sony display requested to power off"
        end

        # Request status update
        power?
    end

    def power?(options = {})
        options[:priority] = 0
        options[:hex_string] = true
        send("83 00 00 FF FF 81", options)
    end

    def received(byte_str, resolve, command)        # Data is default received as a string
        logger.debug { "sony display sent: 0x#{byte_to_hex(byte_str)}" }
        if byte_str.start_with?("\x70\x0\x0\x1")
          self[:power] = true
        elsif byte_str == "\x70\x0\x0\x0\x72"
          self[:power] = false
        end
        :success
    end
end
