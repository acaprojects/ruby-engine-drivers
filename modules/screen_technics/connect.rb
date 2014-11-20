module ScreenTechnics; end

# Port 80
# Make break?

class ScreenTechnics::Connect
	include ::Orchestrator::Constants


	def on_load
	end

	def on_unload
	end
	
	def on_update
	end
	
	def connected
	end
	
	def disconnected
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
		send("POST /ADirectControl.html HTTP/1.1\r\nContent-Length: 10\r\n\r\nDown#{index}=Down", :name => :position) do
			self[:"screen#{index}"] = :down
			:success
		end
	end

	def up(index = 1)
		stop(index)
		send("POST /ADirectControl.html HTTP/1.1\r\nContent-Length: 6\r\n\r\nUp#{index}=Up", :name => :position) do
			self[:"screen#{index}"] = :up
			:success
		end
	end

	def stop(index = 1)
		send("POST /ADirectControl.html HTTP/1.1\r\nContent-Length: 10\r\n\r\nStop#{index}=Stop", {:delay_on_receive => 3, :name => :stop})
	end
	
	
	def received(data, resolve, command)
		:success
	end
end
