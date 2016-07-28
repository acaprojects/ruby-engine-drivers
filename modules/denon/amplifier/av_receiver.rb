# encoding: US-ASCII
module Denon; end
module Denon::Amplifier; end


#
#     NOTE:: Denon doesn't respond to commands that request the current state
#         (ie if the volume is 100 and you request 100 it will not respond)
#


class Denon::Amplifier::AvReceiver
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 23 # Telnet
    descriptive_name 'Denon AVR (Switcher Amplifier)'
    generic_name :Switcher

    # Communication settings
    tokenize delimiter: "\x0D"

    # Denon requires some breathing room
    delay between_sends: 30
    delay on_receive: 30


    def on_load
        self[:volume_min] = 0
        self[:volume_max] = 196 # == 98 * 2    - Times by 2 so we can account for the half steps
        on_update
    end
    
    def on_update
        defaults max_waits: 10, timeout: 3000
    end
    
    
    def connected
        #
        # Get state
        #
        send_query(COMMANDS[:power])
        send_query(COMMANDS[:input])
        send_query(COMMANDS[:volume])
        send_query(COMMANDS[:mute])
        
        @polling_timer = schedule.every('60s') do
            logger.debug "-- Polling Denon AVR"
            power?(priority: 0)
            send_query(COMMANDS[:input], priority: 0)
        end
    end
    
    def disconnected
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end
    
    
    COMMANDS = {
        power:  :PW,
        mute:   :MU,
        volume: :MV,
        input:  :SI
    }
    COMMANDS.merge!(COMMANDS.invert)
    
    
    def power(state)
        state = is_affirmative?(state)
        
        # self[:power] is current as we would be informed otherwise
        if state && !self[:power]        # Request to power on if off
            send_request(COMMANDS[:power], 'ON', timeout: 10, delay_on_receive: 3, name: :power)    # Manual states delay for 1 second, just to be safe
            
        elsif !state && self[:power]    # Request to power off if on
            send_request(COMMANDS[:power], 'STANDBY', timeout: 10, delay_on_receive: 3, name: :power)
        end
    end
    
    def power?(options = {}, &block)
        options[:emit] = {:power => block} unless block.nil?
        send_query(COMMANDS[:power], options)
    end
    
    
    def mute(state = true)
        will_mute = is_affirmative?(state)
        req = will_mute ? 'ON' : 'OFF'
        return if self[:mute] == will_mute
        send_request(COMMANDS[:mute], req)
    end
    alias_method :mute_audio, :mute
    
    def unmute
        mute false
    end
    alias_method :unmute_audio, :unmute

    
    def volume(level)
        value = in_range(level.to_i, 196)
        return if self[:volume] == value

        # The denon is weird 99 is volume off, 99.5 is the minimum volume, 0 is the next lowest volume and 985 is the loudest volume
        # => So we are treating 99, 995 and 0 as 0
        step = value % 2
        actual = value / 2
        req = actual.to_s.rjust(2, '0')
        req += '5' if step != 0

        send_request(COMMANDS[:volume], req, name: :volume)    # Name prevents needless queuing of commands
        self[:volume] = value
    end
    
    
    
    # Just here for documentation (there are many more)
    #
    #INPUTS = [:cd, :tuner, :dvd, :bd, :tv, :"sat/cbl", :dvr, :game, :game2, :"v.aux", :dock]
    def switch_to(input)
        status = input.to_s.downcase.to_sym
        if status != self[:input]
            input = input.to_s.upcase
            send_request(COMMANDS[:input], input, name: :input)
            self[:input] = status
        end
    end
    
    
    
    def received(data, resolve, command)
        logger.debug { "Denon sent #{data}" }
        
        comm = data[0..1].to_sym
        param = data[2..-1]
        
        case COMMANDS[comm]
        when :power
            self[:power] = param == 'ON'
            
        when :input
            self[:input] = param.downcase.to_sym
            
        when :volume
            return :ignore if param.length > 3    # May send 'MVMAX 98' after volume command
            
            vol = param[0..1].to_i * 2
            vol += 1 if param.length == 3
            
            vol == 0 if vol > 196            # this means the volume was 99 or 995
            
            self[:volume] = vol
            
        when :mute
            self[:mute] = param == 'ON'
            
        else
            return :ignore
        end

        return :success
    end
    
    
    protected
    
    
    def send_request(command, param, options = {})
        logger.debug { "Requesting #{command}#{param}" }
        send("#{command}#{param}\r", options)
    end
    
    def send_query(command, options = {})
        logger.debug { "Requesting #{command}" }
        send("#{command}?\r", options)
    end
end

