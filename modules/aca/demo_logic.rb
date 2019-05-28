module Aca; end

class Aca::DemoLogic
    include ::Orchestrator::Constants

    descriptive_name 'ACA Demo Logic'
    generic_name :Demo
    implements :logic


    def on_load
        self[:name] = system.name
        self[:volume] = 0
        self[:mute] = false
        self[:views] = 0
        self[:state] = 'Idle'
    end

    def on_update
        schedule.clear
        schedule.every('10s') { update_state }
    end

    def play
        state('Playing');
    end

    def stop
        state('Stopped')
    end

    def volume(value)
        self[:volume] = value
        if self[:volume] > 100
            self[:volume] = 100
        elsif self[:volume] < 0
            self[:volume] = 0
        end
    end

    def mute(state)
        self[:mute] = state
    end

    def update_state
        if self[:state] == 'Stopped'
            state('Idle')
        end
        self[:views] += rand(7)
    end

    def state(status)
        self[:state] = status
    end
end
