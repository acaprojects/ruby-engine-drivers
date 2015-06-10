# encoding: US-ASCII

module Symetrix; end

# Protocol 2 - supports both TCP and UDP operations
# port 48631

class Symetrix::Composer
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    
    def on_load
        config({
            tokenize: true,
            delimiter: "\r"
        })

        @type_lookup = {}
    end
    
    def on_unload
    end
    
    def on_update
        self[:fader_min] = setting(:fader_min) || 0
        self[:fader_max] = setting(:fader_max) || 65535
    end
    
    
    def connected
        do_send('EH', 0) # Echo off
        do_send('SQ', 1) # Quiet mode on
        push_threshold(65535, :METER) # Never send us meter values
        push_threshold(1, :PARAMETER) # Always send us data values
        enable_push
        push  # Push all value changes
        
        # Maintain the connection
        @polling_timer = schedule.every('60s') do
            nop({ priority: 0 })
        end
    end
    
    def disconnected
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end
    
    
    def preset(number)
        do_send('LP', number)
    end

    # Flashes the LEDS on the front of the unit
    def flash_leds(cycles = 8, options = {})
        do_send('FU', cycles, options)
    end

    def enable_push(state = true, low = nil, high = nil)
        value = is_affirmative?(state) ? 1 : 0
        do_send('PU', value, low, high)
    end

    def reboot
        do_send('R!')
    end

    def nop(options = {})
        do_send('NOP', options)
    end

    # Val == milliseconds
    def push_interval(val = 100)
        do_send('PUI', val)
    end

    # Alternative Type is: PARAMETER
    def push_threshold(value, type = :METER)
        do_send('PUT', type, in_range(value, 65535))
    end

    # Nil values enable push for the entire range
    def push(low = nil, high = nil)
        do_send('PUE', low, high)
    end

    # disables push
    def push(low = nil, high = nil)
        do_send('PUD', low, high)
    end

    # Send all values again
    def push_refresh
        do_send('PUR')
    end

    # Don't send any values until next change
    def push_clear
        do_send('PUC')
    end

    
    def get_control_value(id, type)
        @type_lookup[id.to_i] = type

        # NOTE:: There is also a GS command however it doesn't
        #         return a control ID with the response
        # Returns: id value
        do_send('GS2', id)
    end

    # Note: Mutes are 0 (off) or 65535 (on)
    def set_control_value(id, value, type)
        @type_lookup[id.to_i] = type
        value = in_range(value, 65535)

        # Inline response processing is easiest
        do_send('CS', id, value) do |data, resolve, command|
            if data == 'ACK'
                if type == :mute
                    self[:"fader#{id}_mute"] = value == 65535
                else
                    self[:"fader#{id}"] = value
                end
                :success
            else
                # Delegate if the reponse wasn't for us
                received(data, resolve, command)

                # and ignore
                :ignore
            end
        end
    end



    # For compatibility with other modules
    def fader(fader_id, level)
        faders = fader_id.is_a?(Array) ? fader_id : [fader_id]
        faders.each do |fad|
            set_control_value(fad, level, :fader)
        end
    end
    # Named params version
    def faders(ids:, level:)
        fader(ids, level)
    end
    
    def mute(fader_id, val = true)
        actual = val ? 65535 : 0

        faders = fader_id.is_a?(Array) ? fader_id : [fader_id]
        faders.each do |fad|
            set_control_value(fad, actual, :mute)
        end
    end
    # Named params version
    def mutes(ids:, muted: true)
        mute(ids, muted)
    end
    
    def unmute(fader_id)
        mute(fader_id, false)
    end

    def query_fader(fader_id)
        fad = fader_id.is_a?(Array) ? fader_id[0] : fader_id

        get_control_value(fad, :fader)
    end
    # Named params version
    def query_faders(ids:)
        query_fader(ids)
    end

    def query_mute(fader_id)
        fad = fader_id.is_a?(Array) ? fader_id[0] : fader_id
        
        get_control_value(fad, :mute)
    end
    # Named params version
    def query_mutes(ids:)
        query_mute(ids)
    end
    
    
    def received(data, resolve, command)
        logger.debug "received #{data}"

        return :success if data == 'ACK'
        return :abort if data == 'NAK'
        
        # Can be space or equals sign
        resp = data.split(' ')
        if resp.length > 1
            process_reponse(*resp)
        else
            resp = data.split('=')
            process_reponse(*resp) if resp.length > 1
        end
        
        return :success
    end
    
    
    private


    def process_reponse(id, value, *args)
        id = id.gsub('#', '').to_i if id.is_a? String

        type = @type_lookup[id]
        return unless type

        value = value.to_i

        if type == :mute
            self[:"fader#{id}_mute"] = value == 65535
        else
            self[:"fader#{id}"] = value
        end
    end
    
    def do_send(*args, &block)
        options = args[-1].is_a?(Hash) ? args.pop : {}
        send("#{args.join(' ')}\r", options, &block)
    end
end

