module ScreenTechnics; end


class ScreenTechnics::Connect
    include ::Orchestrator::Constants


    # Discovery Information
    implements :service
    descriptive_name 'Screen Technics Projector Screen Control'
    generic_name :Screen

    # Communication settings
    delay between_sends: 2000
    keepalive false
    inactivity_timeout 1500


    def on_load
        self[:state] = :up
    end
    
    def on_update
    end
    
    def connected
    end
    
    def state(new_state, index = 1)
        if is_affirmative?(new_state)
            down(index)
        else
            up(index)
        end
    end

    def down(index = 1)
        if self[:"screen#{index}"] == :down
            down_only(index)
        else
            stop(index)
            down_only(index)
        end
    end

    def down_only(index = 1)
        do_send({
            state: :down,
            body: "Down#{index}=Down",
            name: :"position#{index}",
            index: index
        })
    end

    def up(index = 1)
        if self[:"screen#{index}"] == :up
            up_only(index)
        else
            stop(index)
            up_only(index)
        end
    end

    def up_only(index = 1)
        do_send({
            state: :up,
            body: "Up#{index}=Up",
            name: :"position#{index}",
            index: index
        })
    end

    def stop(index = 1)
        do_send({
            body: "Stop#{index}=Stop",
            name: :"stop#{index}",
            priority: 99
        })
    end


    protected


    def do_send(options)
        state = options.delete(:state)
        index = options.delete(:index)
        post('/ADirectControl.html', options) do
            self[:"screen#{index}"] = state if state
            :success
        end
    end
end
