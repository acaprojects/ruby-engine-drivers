module Aca; end

# Logic module
# Abstracts screen or projector lift up and down control
# Where the DigitalIO device supports plusing deals with the timers

class Aca::LifterLogicAuto
    include ::Orchestrator::Constants

    def on_load
        on_update
    end

    def on_update
        @module = setting(:module) || :DigitalIO
        @index = setting(:index) || 1

        # {"up": [[index, state, time]]}
        @up_config = setting(:up)
        @down_config = setting(:down)

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
        mod.relay(*cmd)
        mod.relay(*cmd) if cmd.length > 2

        self[:"lifter#{index}"] = :up
    end

    def down(index = 1)
        pos = index - 1
        mod = system.get(@module, @index)
        cmd = @down_config[pos]

        mod.relay(*cmd)
        mod.relay(*cmd) if cmd.length > 2

        self[:"lifter#{index}"] = :down
    end

    def rotate(state, index = 1)
        pos = index - 1
        mod = system.get(@module, @index)

        type = is_affirmative?(state) ? :active : :inactive
        cmd = @rotate_config[pos][type]

        mod.relay(*cmd)
        mod.relay(*cmd) if cmd.length > 2

        self[:"lifter#{index}_rotation"] = type
    end
end
