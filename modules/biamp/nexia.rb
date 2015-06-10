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

        # Nexia requires some breathing room
        defaults({
            delay_on_receive: 30,
            delay: 30
        })

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
                    do_send('SET', self[:device_id], req, id, input, output, value)
                end
            end
        else # assume array (auto-mixer)
            inouts.each do |input|
                do_send('SET', self[:device_id], 'AMMUTEXP', id, input, value)
            end
        end
    end

    FADERS = {
        fader: :FDRLVL,
        matrix_in: :MMLVLIN,
        matrix_out: :MMLVLOUT,
        matrix_crosspoint: :MMLVLXP,
        stdmatrix_in: :SMLVLIN,
        stdmatrix_out: :SMLVLOUT,
        auto_in: :AMLVLIN,
        auto_out: :AMLVLOUT,
        io_in: :INPLVL,
        io_out: :OUTLVL
    }
    FADERS.merge!(FADERS.invert)
    def fader(fader_id, level, index = 1, type = :fader)
        fad_type = FADERS[type.to_sym]

        # value range: -100 ~ 12
        faders = fader_id.is_a?(Array) ? fader_id : [fader_id]
        faders.each do |fad|
            do_send('SETD', self[:device_id], fad_type, fad, index, level)
        end
    end
    # Named params version
    def faders(ids:, level:, index: 1, type: :fader)
        fader(ids, level, index, type)
    end
    
    MUTES = {
        fader: :FDRMUTE,
        matrix_in: :MMMUTEIN,
        matrix_out: :MMMUTEOUT,
        auto_in: :AMMUTEIN,
        auto_out: :AMMUTEOUT,
        stdmatrix_in: :SMMUTEIN,
        stdmatrix_out: :SMOUTMUTE,
        io_in: :INPMUTE,
        io_out: :OUTMUTE
    }
    MUTES.merge!(MUTES.invert)
    def mute(fader_id, val = true, index = 1, type = :fader)
        value = is_affirmative?(val)
        actual = value ? 1 : 0
        mute_type = MUTES[type.to_sym]

        faders = fader_id.is_a?(Array) ? fader_id : [fader_id]
        faders.each do |fad|
            do_send('SETD', self[:device_id], mute_type, fad, index, actual)
        end
    end
    # Named params version
    def mutes(ids:, muted: true, index: 1, type: :fader)
        mute(ids, muted, index, type)
    end
    
    def unmute(fader_id, index = 1, type = :fader)
        mute(fader_id, false, index, type)
    end

    def query_fader(fader_id, index = 1, type = :fader)
        fad = fader_id.is_a?(Array) ? fader_id[0] : fader_id
        fad_type = FADERS[type.to_sym]

        do_send('GETD', self[:device_id], fad_type, fad, index)
    end
    # Named params version
    def query_faders(ids:, index: 1, type: :fader)
        query_fader(ids, index, type)
    end

    def query_mute(fader_id, index = 1, type = :fader)
        fad = fader_id.is_a?(Array) ? fader_id[0] : fader_id
        mute_type = MUTES[type.to_sym]
        
        do_send('GETD', self[:device_id], mute_type, fad, index)
    end
    # Named params version
    def query_mutes(ids:, index: 1, type: :fader)
        query_mute(ids, index, type)
    end
    
    
    def received(data, resolve, command)
        if data =~ /-ERR/
            if command
                logger.warn "Nexia returned #{data} for #{command[:data]}"
            else
                logger.debug { "Nexia responded #{data}" }
            end
            return :abort
        else
            logger.debug { "Nexia responded #{data}" }
        end
        
        #--> "#SETD 0 FDRLVL 29 1 0.000000 +OK"
        data = data.split(' ')
        unless data[2].nil?
            resp_type = data[2].to_sym

            if resp_type == :DEVID
                # "#GETD 0 DEVID 1 "
                self[:device_id] = data[-1].to_i
            elsif MUTES.has_key?(resp_type)
                type = MUTES[resp_type]
                self[:"#{type}#{data[3]}_#{data[4]}_mute"] = data[5] == '1'
            elsif FADERS.has_key?(resp_type)
                type = FADERS[resp_type]
                self[:"#{type}#{data[3]}_#{data[4]}"] = data[5].to_i
            end
        end
        
        return :success
    end
    
    
    private
    
    
    def do_send(*args, &block)
        if args[-1].is_a? Hash
            options = args.pop
        else
            options = {}
        end
        send("#{args.join(' ')} \n", options, &block)
    end
end

