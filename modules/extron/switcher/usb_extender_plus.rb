# encoding: ASCII-8BIT

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



class Extron::Switcher::UsbExtenderPlus < Extron::Base
    # Discovery Information
    tcp_port 23
    descriptive_name 'Extron USB Extender Plus'
    generic_name :Switcher


    def on_load
        on_update
    end

    def on_update
        # The transmitter is the computer / host
        @mac_address = clean(setting(:mac_address))
        @host_ip = remote_address
        @port = setting(:pair_port) || 6137

        # Receivers are the devices, like keyboards and mice
        # { "location name": ["ip", "mac_address", port] } # port is optional
        self[:receivers] = setting(:receivers) || {}
        @lookup = self[:receivers].values
    end


    def switch_to(input)
        receiver = input.is_a?(Integer) ? @lookup[input] : self[:receivers][input.to_sym]
        if receiver
            unpair_all

            # pair just this receiver to this transmitter
            to_host = "2f03f4a2020000000302#{clean(receiver[1])}"
            thread.udp_service.send(@host_ip, @port, to_host)

            to_device = "2f03f4a2020000000302#{@mac_address}"
            thread.udp_service.send(receiver[0], receiver[2] || @port, to_device)
        else
            logger.warn("#{input} receiver not found")
        end
    end

    def switch(map)
        unpair_all

        map.each do |_, outputs|
            outputs = Array(outputs)

            outputs.each do |input|
                receiver = input.is_a?(Integer) ? @lookup[input] : self[:receivers][input.to_sym]
                if receiver
                    # pair this receiver to this transmitter
                    to_host = "2f03f4a2020000000302#{clean(receiver[1])}"
                    thread.udp_service.send(@host_ip, @port, to_host)

                    to_device = "2f03f4a2020000000302#{@mac_address}"
                    thread.udp_service.send(receiver[0], receiver[2] || @port, to_device)
                else
                    logger.warn("#{input} receiver not found")
                end
            end
        end
    end

    def unpair_all
        @lookup.each do |receiver|
            to_host = "2f03f4a2020000000303#{clean(receiver[1])}"
            thread.udp_service.send(@host_ip, @port, to_host)

            to_device = "2f03f4a2020000000303#{@mac_address}"
            thread.udp_service.send(receiver[0], receiver[2] || @port, to_device)
        end
    end


    def keyboard_emulation(enable)
        val = is_affirmative?(enable) ? 1 : 0
        do_send("\eE#{val}USBC", name: :emulation)
    end

    def is_keyboard_emulated?
        do_send("\eEUSBC", name: :emulation_query)
    end

    def network_pairing(enable)
        val = is_affirmative?(enable) ? 1 : 0
        do_send("\eN#{val}USBC", name: :pair)
    end

    def can_network_pair?
        do_send("\eNUSBC", name: :pair_query)
    end


    ERRORS = {
        10 => 'Invalid command',
        12 => 'Invalid port number',
        13 => 'Invalid parameter (number is out of range)',
        14 => 'Not valid for this configuration',
        22 => 'Busy',
        24 => 'Privilege violation',
        25 => 'Device is not present'
    }


    def received(data, resolve, command)
        logger.debug { "Extron USB sent #{data}" }

        if data =~ /Login/i
            device_ready
        elsif data[0] == 'E'
            logger.info "Extron Error #{ERRORS[data[1..2].to_i]}"
            logger.info "- for command #{command[:data]}" unless command.nil?
        elsif command && command[:name]
            case command[:name]
            when :emulation
                # UsbcE1
                self[:emulating] = data[5] == '1'
            when :emulation_query
                self[:emulating] = data[0] == '1'
            when :pair
                # UsbcN1
                self[:pairing_enabled] = data[5] == '1'
            when :pair_query
                self[:pairing_enabled] = data[0] == '1'
            end
        end

        return :success
    end


    protected


    def clean(mac)
        mac.gsub(/(0x|[^0-9A-Fa-f])*/, '')
    end

    def device_ready
        do_send("\e3CV", :wait => true)    # Verbose mode and tagged responses
        network_pairing(true)
    end
end
