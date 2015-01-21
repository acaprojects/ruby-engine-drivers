# encoding: US-ASCII

module Biamp; end

# TELNET port 23

class Biamp::Nexia
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    
    def on_load
        self[:fader_min] = -36        # specifically for tonsley
        self[:fader_max] = 12

        # max +12
        # min -100

        config({
            tokenize: true,
            delimiter: /\xFF\xFE\x01|\r\n/
        })
    end
    
    def on_unload
    end
    
    def on_update
    end
    
    
    def connected
        send("\xFF\xFE\x01")    # Echo off
        do_send('GETD', 0, 'DEVID')
        
        @polling_timer = schedule.every('60s') do
            do_send('GETD', 0, 'DEVID')
        end
    end
    
    def disconnected
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end
    
    
    def preset(number)
        #
        # Recall Device 0 Preset number 1001
        # Device Number will always be 0 for Preset strings
        # 1001 == minimum preset number
        #
        do_send('RECALL', 0, 'PRESET', number)
    end

    # {1 => [2,3,5], 2 => [2,3,6]}, true
    # Supports Matrix and Automixers
    def mixer(id, inouts, mute = false)
        value = is_affirmative?(mute) ? 1 : 0

        if inouts.is_a? Hash
            inouts.each_key do |input|
                outputs = inouts[input]
                outs = outputs.is_a?(Array) ? outputs : [outputs]

                outs.each do |output|
                    do_send('SETD', self[:device_id], 'MMMUTEXP', id, input, output, value)
                end
            end
        else # assume array (auto-mixer)
            inouts.each do |input|
                do_send('SETD', self[:device_id], 'AMMUTEXP', id, input, value)
            end
        end
    end
    
    def fader(fader_id, level, index = 1)
        # value range: -100 ~ 12
        faders = fader_id.is_a?(Array) ? fader_id : [fader_id]
        faders.each do |fad|
            do_send('SETD', self[:device_id], 'FDRLVL', fad, index, level)
        end
    end
    
    def mute(fader_id, val = true, index = 1)
        actual = val ? 1 : 0
        faders = fader_id.is_a?(Array) ? fader_id : [fader_id]
        faders.each do |fad|
            do_send('SETD', self[:device_id], 'FDRMUTE', fad, index, actual)
        end
    end
    
    def unmute(fader_id, index = 1)
        mute(fader_id, false, index)
    end

    def query_fader(fader_id, index = 1)
        fad = fader_id.is_a?(Array) ? fader_id[0] : fader_id

        send("GET #{self[:device_id]} FDRLVL #{fad} #{index} \n") do |data|
            if data.start_with?('-ERR')
                :abort
            else
                self[:"fader#{fad}_#{index}"] = data.to_i
                :success
            end
        end
    end

    def query_mute(fader_id, index = 1)
        fad = fader_id.is_a?(Array) ? fader_id[0] : fader_id
        
        send("GET #{self[:device_id]} FDRMUTE #{fad} #{index} \n") do |data|
            if data.start_with?('-ERR')
                :abort
            else
                self[:"fader#{fad}_#{index}_mute"] = data.to_i == 1
                :success
            end
        end
    end
    
    
    def received(data, resolve, command)
        if data.start_with?('-ERR')
            logger.debug "Nexia returned #{data} for #{command[:data]}" if command
            return :abort
        end
        
        #--> "#SETD 0 FDRLVL 29 1 0.000000 +OK"
        data = data.split(' ')
        unless data[2].nil?
            case data[2].to_sym
            when :FDRLVL, :VL
                self[:"fader#{data[3]}_#{data[4]}"] = data[5].to_i
            when :FDRMUTE
                self[:"fader#{data[3]}_#{data[4]}_mute"] = data[5] == "1"
            when :DEVID
                # "#GETD 0 DEVID 1 "
                self[:device_id] = data[-2].to_i
            end
        end
        
        return :success
    end
    
    
    
    private
    
    
    def do_send(*args)
        send("#{args.join(' ')} \n")
    end
end

