module ScreenTechnics; end


class ScreenTechnics::Connect
	include ::Orchestrator::Constants


	def on_load
		defaults({
            delay: 2000,
            keepalive: false,
            inactivity_timeout: 1.5,  # seconds before closing the connection if no response
            connect_timeout: 2        # max seconds for the initial connection to the device
        })

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
		stop(index)
		do_send({
			state: :down,
			body: "Down#{index}=Down",
			name: :"position#{index}",
			index: index
		})
	end

	def up(index = 1)
		stop(index)
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
