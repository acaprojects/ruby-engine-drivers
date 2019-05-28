# encoding: ASCII-8BIT
module Cisco::TelePresence::SxMixerCommon
    def on_load
        super
        on_update
    end
    
    def on_update
    end
    
    def connected
        self[:power] = true
        super
        do_poll
        schedule.every('30s') do
            logger.debug "-- Polling VC Volume"
            do_poll
        end
    end
    
    def disconnected
        self[:power] = false
        super
        schedule.clear
    end

    def power(state)
        self[:power]  # Here for compatibility with other camera modules
    end

    def power?(options = nil, &block)
        block.call unless block.nil?
        self[:power]
    end
    
    def fader(_, value)
        vol = in_range(value.to_i, 100, 0)
        command('Audio Volume Set', params({
            level: vol
        }), name: :volume).then do
            self[:faderOutput] = vol
        end
    end

    def faders(ids:, level:, **_)
       fader(nil, level)
    end
    
    def mute(_, state)
        value = is_affirmative?(state) ? 'Mute' : 'Unmute'
        command("Audio Volume #{value}", name: :mute).then do
            self[:faderOutput_mute] = value
        end
    end

    def mutes(ids:, muted:, **_)
        mute(muted)
    end


    # ---------------
    # STATUS REQUESTS
    # ---------------
    def volume?
        status "Audio Volume", priority: 0, name: :volume?
    end

    def muted?
        status "Audio VolumeMute", priority: 0, name: :muted?
    end

    def do_poll
        volume?
        muted?
    end
    
    IsResponse = '*s'.freeze
    IsComplete = '**'.freeze
    def received(data, resolve, command)
        logger.debug { "Cisco SX Mixer sent #{data}" }
        result = Shellwords.split data
        if command
            if result[0] == IsComplete
                return :success
            elsif result[0] != IsResponse
                return :ignore
            end
        end
        if result[0] == IsResponse
            type = result[2].downcase.gsub(':', '').to_sym
            case type
            when :volume
                self[:faderOutput] = result[-1].to_i
            when :volumemute
                self[:faderOutput_mute] = result[-1].downcase != 'off'
            end
            return :ignore
        end
        return :success
    end
end