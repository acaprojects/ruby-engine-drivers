module Aca; end

# Logic module
# Abstracts screen or projector lift up and down control
# Where the DigitalIO does not have a pulse command and timers are required

class Aca::LifterLogicManual
    include ::Orchestrator::Constants

    def on_load
        @next = {}
        @pulsing = {}

        on_update
    end

    def on_update
        @module = setting(:module) || :DigitalIO
        @index = setting(:index) || 1

        # {"up": [[index, state, time]]}
        @up_config = setting(:up)
        @down_config = setting(:down)
        @stop_config = setting(:stop)

        # {"rotate": [{"active": [index, state, time], "inactive": [index, state, time]}]}
        @rotate_config = setting(:rotate)
    end


    def state(val, index = 1)
        if is_affirmative?(val)
            down(index)
        else
            up(index)
        end
    end

    def up(index = 1)
        pos = index - 1
        mod = system.get(@module, @index)
        cmd = @up_config[pos]

        # Send twice as screen will stop if moving the first pulse
        # Then the second pulse will cause it to change direction
        pulse(mod, *cmd)
        pulse(mod, *cmd) if cmd.length > 2

        self[:"lifter#{index}"] = :up
    end
    alias_method :close, :up

    def down(index = 1)
        pos = index - 1
        mod = system.get(@module, @index)
        cmd = @down_config[pos]

        pulse(mod, *cmd)
        pulse(mod, *cmd) if cmd.length > 2

        self[:"lifter#{index}"] = :down
    end
    alias_method :open, :down

    def stop(index = 1)
        pos = index - 1
        mod = system.get(@module, @index)
        cmd = @stop_config[pos]

        logger.debug "stopping..."

        pulse(mod, *cmd)
        pulse(mod, *cmd) if cmd.length > 2
    end

    def rotate(state, index = 1)
        pos = index - 1
        mod = system.get(@module, @index)

        type = is_affirmative?(state) ? :active : :inactive
        cmd = @rotate_config[pos][type]

        pulse(mod, *cmd)
        pulse(mod, *cmd) if cmd.length > 2

        self[:"lifter#{index}_rotation"] = type
    end


    protected


    def pulse(mod, relay, state, time = nil, delay = nil)

        if time.nil?
            # On == up and Off == down etc
            mod.relay relay, state

        elsif time && @pulsing[relay].nil?
            # Pulse to move up / down
            mod.relay relay, state

            @pulsing[relay] = schedule.in("#{time}s") do
                @pulsing.delete(relay)
                if delay
                    mod.relay relay, !state, delay: (delay * 1000)
                else
                    mod.relay relay, !state
                end

                if @next[relay]
                    args = @next[relay]
                    @next.delete(relay)
                    pulse *args
                end
            end
        else

            # A pulse is already in progress. Lets wait it out
            @next[relay] = [mod, relay, state, time]
        end
    end
end
