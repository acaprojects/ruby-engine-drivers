module Aca; end

#
# Settings required:
#	* domain (domain that we will be authenticating against)
#	* username (username for authentication)
#	* password (password for authentication)
#
# (built in)
# connected
#
class Aca::PcControl
	include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

	#
	# 	initialize will not have access to settings
	#
	def on_load
		
		#
		# Setup constants
		#
		self[:authenticated] = 0

		config({
			tokenize: true,
			delimiter: "\x03",
			indicator: "\x02"
		})
	end
	
	def connected
		@polling_timer = schedule.every('60s') do
            logger.debug "-- Polling Computer"
            do_send({:control => "app", :command => 'do_nothing'}, {wait: false})
        end
	end
	
	def disconnected
		self[:authenticated] = 0
		@polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
	end
	
	def launch_application(app, *args)
		do_send({:control => "app", :command => app, :args => args})
	end

	def wake(broadcast = nil)
		mac = setting(:mac_address)
        if mac
            # config is the database model representing this device
            wake_device(mac, broadcast || '<broadcast>')
        end
        logger.debug "Waking computer #{mac} #{broadcast}"
        nil
	end

	def shutdown
		launch_application 'shutdown.exe', '/s', '/t', '0'
	end

	def logoff
		launch_application 'shutdown.exe', '/l', '/t', '0'
	end

	def restart
		launch_application 'shutdown.exe', '/r', '/t', '0'
	end
	


	#
	# Camera controls
	#
	CAM_OPERATIONS = [:up, :down, :left, :right, :center, :zoomin, :zoomout]
	
	#
	# Automatically creates a callable function for each command
	#	http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
	#	http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
	#
	CAM_OPERATIONS.each do |command|
		define_method command do |*args|
			# Cam control is low priority in case a camera is not plugged in
			do_send({:control => "cam", :command => command.to_s, :args => []}, {:priority => 0, :retries => 0})
		end
	end
	
	def zoom(val)
		do_send({:control => "cam", :command => "zoom", :args => [val.to_s]})
	end
	
	def received(data, resolve, command)
		
		#
		# Convert the message into a native object
		#
		data = JSON.parse(data, {:symbolize_names => true})
		
		#
		# Process the response
		#
		if data[:command] == "authenticate"
			command = {:control => "auth", :command => setting(:domain), :args => [setting(:username), setting(:password)]}
			if self[:authenticated] > 0
				#
				# Token retry (probably always fail - at least we can see in the logs)
				#	We don't want to flood the network with useless commands
				#
				schedule.in('60s') do
					do_send(command)
				end
				logger.info "-- Pod Computer, is refusing authentication"
			else
				do_send(command)
			end
			self[:authenticated] += 1
			logger.debug "-- Pod Computer, requested authentication"
		elsif data[:type] != nil
			self["#{data[:device]}_#{data[:type]}"] = data	# zoom, tilt, pan
			return nil	# This is out of order data
		else
			if !data[:result]
				logger.warn "-- Pod Computer, request failed for command: #{command ? command[:data] : "(resp #{data})"}"
				return false
			end
		end
		
		return true # Command success
	end
	
	
	private
	

	def do_send(command, options = {})
		send("\x02#{JSON.generate(command)}\x03", options)
	end
end

