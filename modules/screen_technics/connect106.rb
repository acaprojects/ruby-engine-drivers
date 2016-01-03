module ScreenTechnics; end

# Connect version 1.06

class ScreenTechnics::Connect106
    include ::Orchestrator::Constants


    # Discovery Information
    implements :service
    descriptive_name 'Screen Technics Projector Screen Control 1.06'
    generic_name :Screen

    # Communication settings
    delay between_sends: 3000
    keepalive false
    inactivity_timeout 1500


    def on_load
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
        stop(index)
        do_send({
            state: :down,
            body: {"Down#{index}" => "Down"},
            name: :"position#{index}",
            index: index
        })
    end

    def up(index = 1)
        stop(index)
        do_send({
            state: :up,
            body: {"Up#{index}" => "Up"},
            name: :"position#{index}",
            index: index
        })
    end

    def stop(index = 1)
        do_send({
            body: {"Stop#{index}" => "Stop"},
            name: :"stop#{index}",
            priority: 99,
            clear_queue: true
        })
    end


    protected


    def do_send(options)
        state = options.delete(:state)
        index = options.delete(:index)
        options[:headers] ||= {}
        options[:headers][:cookie] = {
            :LoggedIn => :Technical,
            :IRSel => 1,
            :SWSel => 1,
            :MAFSel => 1,
            :IDSel => 1
        }
        post('/TDirectControl', options) do
            self[:"screen#{index}"] = state if state
            :success
        end
    end
end
