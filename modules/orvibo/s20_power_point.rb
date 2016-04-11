module Orvibo; end

class Orvibo::S20PowerPoint
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Attempt to load the mac address discovery gem
    begin
        require 'macaddr'
        CAN_MACADDR = true
    rescue LoadError
        CAN_MACADDR = false
    end


    # Discovery Information
    udp_port 10000
    descriptive_name 'Orvibo S20 Wifi Power Point'
    generic_name :PowerPoint
    default_settings mac_address: 'ac cf 23 24 19 c0'


    # Communication settings
    tokenise indicator: "\x68\x64", callback: :check_length
    delay between_sends: 200


    def on_load
        on_update
    end

    def on_update
        # This is the mac address of the server
        mac_address = setting(:mac_address)
        if mac_address.nil? && CAN_MACADDR
            # This may not be the correct address so a setting if preferred
            mac_address = ::Mac.address
        end

        if mac_address
            @mac_address = hex_to_byte(mac_address).freeze
        end
    end

    MAC_Padding = '      '.freeze
    Magic_Key = "\x68\x64".freeze

    
    def connected
        # Maintain UDP subscription
        subscribe
        @polling_timer = schedule.every('60s') do
            subscribe
        end
    end


    Commands = {
        subscribe: '\x63\x6C',
        power: '\x73\x66'
    }
    Commands.merge!(Commands.invert)


  
    def received(data, resolve, command)
        logger.debug { "received: 0x#{byte_to_hex(data)}" }

        len = data[0..1]
        cmd = data[2..3]

        case Commands[cmd]
        when :subscribe, :power
            self[:power] = data[-1].ord == 1
        end

        :success
    end


    # All Commands apart from discovery require a subscription first!
    def subscribe
        do_send :subscribe, "#{@mac_address}#{MAC_Padding}"
    end

    def power(state)
        flag = is_affirmative?(state) ? '\x01' : '\x00'
        do_send :power, "\x00\x00\x00\x00#{flag}"
    end


    protected


    def do_send(cmd, data)
        str = "#{Commands[cmd]}#{@mac_address}#{MAC_Padding}#{data}"
        len = str.length + 4
        str = "#{Magic_Key}#{hex_to_byte(en.to_s(16).rjust(4, '0'))}#{str}"

        send str, name: cmd
    end

    # This checks if we have received all the data for a response
    def check_length(byte_str)
        return false if byte_str.length <= 2

        # Extract the message length
        # We subtract 2 as the indicator / magic key has been removed
        len = byte_str[0..1].unpack('n') - 2

        if byte_str.length >= len
            return len
        else
            return false
        end
    end
end

