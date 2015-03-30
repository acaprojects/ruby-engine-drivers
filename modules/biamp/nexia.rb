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
    # Supports Standard, Matrix and Automixers
    # Who thought having 3 different types was a good idea? FFS
    def mixer(id, inouts, mute = false, type = :matrix)
        value = is_affirmative?(mute) ? 0 : 1

        if inouts.is_a? Hash
            req = type == :matrix ? 'MMMUTEXP'.freeze : 'SMMUTEXP'.freeze
            
            inouts.each_key do |input|
                outputs = inouts[input]
                outs = outputs.is_a?(Array) ? outputs : [outputs]

                outs.each do |output|
                    do_send('SETD', self[:device_id], req, id, input, output, value)
                end
            end
        else # assume array (auto-mixer)
            inouts.each do |input|
                do_send('SETD', self[:device_id], 'AMMUTEXP', id, input, value)
            end
        end
    end

    FADERS = {
        fader: 'FDRLVL',
        matrix_in: 'MMLVLIN',
        matrix_out: 'MMLVLOUT',
        matrix_crosspoint: 'MMLVLXP',
        stdmatrix_in: 'MMLVLIN',
        stdmatrix_out: 'MMLVLOUT'
    }
    def fader(fader_id, level, index = 1, type = :fader)
        fad_type = FADERS[type.to_sym]

        # value range: -100 ~ 12
        faders = fader_id.is_a?(Array) ? fader_id : [fader_id]
        faders.each do |fad|
            do_send('SETD', self[:device_id], fad_type, fad, index, level)
        end
    end
    
    MUTES = {
        fader: 'FDRMUTE',
        matrix_in: 'MMMUTEIN',
        matrix_out: 'MMMUTEOUT',
        auto_in: 'AMMUTEIN',
        auto_out: 'AMMUTEOUT',
        stdmatrix_in: 'SMMUTEIN',
        stdmatrix_out: 'SMOUTMUTE'
    }
    def mute(fader_id, val = true, index = 1, type = :fader)
        actual = val ? 1 : 0
        mute_type = MUTES[type.to_sym]

        faders = fader_id.is_a?(Array) ? fader_id : [fader_id]
        faders.each do |fad|
            do_send('SETD', self[:device_id], mute_type, fad, index, actual)
        end
    end
    
    def unmute(fader_id, index = 1, type = :fader)
        mute(fader_id, false, index, type)
    end

    def query_fader(fader_id, index = 1, type = :fader)
        fad = fader_id.is_a?(Array) ? fader_id[0] : fader_id
        fad_type = FADERS[type.to_sym]

        send("GET #{self[:device_id]} #{fad_type} #{fad} #{index} \n") do |data|
            if data.start_with?('-ERR')
                :abort
            else
                self[:"#{type}#{fad}_#{index}"] = data.to_i
                :success
            end
        end
    end

    def query_mute(fader_id, index = 1, type = :fader)
        fad = fader_id.is_a?(Array) ? fader_id[0] : fader_id
        mute_type = MUTES[type.to_sym]
        
        send("GET #{self[:device_id]} #{mute_type} #{fad} #{index} \n") do |data|
            if data.start_with?('-ERR')
                :abort
            else
                self[:"#{mute_type}#{fad}_#{index}_mute"] = data.to_i == 1
                :success
            end
        end
    end
    
    
    def received(data, resolve, command)
        logger.debug { "From biamp #{data}" }

        if data =~ /-ERR/
            logger.warn "Nexia returned #{data} for #{command[:data]}" if command
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
                self[:device_id] = data[-1].to_i
            when :MMLVLIN
                self[:"matrix_in#{data[3]}_#{data[4]}"] = data[5].to_i
            end
        end
        
        return :success
    end
    
    
    
    private
    
    
    def do_send(*args)
        send("#{args.join(' ')} \n")
    end
end

