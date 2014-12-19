module Panasonic; end
module Panasonic::Projector; end


require 'digest/md5'

#
# Port: 1024
#
class Panasonic::Projector::Tcp
	include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

	def on_load
		# Response time is slow
		defaults({
			timeout: 2000,
			delay_on_receive: 1000
		})

		config({
			tokenize: true,
			delimiter: "\r",
			wait_ready: 'NTCONTROL'
		})

		@check_scheduled = false
		self[:power] = false
		self[:stable_state] = true  # Stable by default (allows manual on and off)
		
		# Meta data for inquiring interfaces
		self[:type] = :projector
		
		# The projector drops the connection when there is no activity
		schedule.every('60s') do
			power?({:priority => 0}) if self[:connected]
		end
	end

	def on_update
	end
	
	def connected
	end

	def disconnected
	end


	COMMANDS = {
		power_on: :PON,
		power_off: :POF,
		power_query: :QPW,
		freeze: :OFZ,
		input: :IIS,
		mute: :OSH,
		lamp: :"Q$S"
	}
	COMMANDS.merge!(COMMANDS.invert)
	
	
	
	#
	# Power commands
	#
	def power(state, opt = nil)
		self[:stable_state] = false
		if is_affirmative?(state)
			self[:power_target] = On
			do_send(:power_on, {:retries => 10, :name => :power, delay_on_receive: 8000})
			logger.debug "-- panasonic Proj, requested to power on"
			do_send(:lamp)
		else
			self[:power_target] = Off
			do_send(:power_off, {:retries => 10, :name => :power, delay_on_receive: 8000})
			logger.debug "-- panasonic Proj, requested to power off"
			do_send(:lamp)
		end
	end

	def power?(options = {}, &block)
		options[:emit] = block if block_given?
		do_send(:lamp, options)
	end
	
	
	
	#
	# Input selection
	#
	INPUTS = {
		:hdmi => :HD1,
		:hdmi2 => :HD2,
		:vga => :RG1,
		:vga2 => :RG2,
		:miracast => :MC1
	}
	INPUTS.merge!(INPUTS.invert)
	
	
	def switch_to(input)
		input = input.to_sym
		return unless INPUTS.has_key? input

		# Projector doesn't automatically unmute
		unmute if self[:mute]
		
		do_send(:input, INPUTS[input], {:retries => 10, delay_on_receive: 2000})
		logger.debug "-- panasonic LCD, requested to switch to: #{input}"
		
		self[:input] = input	# for a responsive UI
	end
	
	
	#
	# Mute Audio and Video
	#
	def mute(val = true)
		actual = val ? 1 : 0
		logger.debug "-- panasonic Proj, requested to mute"
		do_send(:mute, actual)	# Audio + Video
	end

	def unmute
		logger.debug "-- panasonic Proj, requested to unmute"
		do_send(:mute, 0)
	end
	
	
	ERRORS = {
		:ERR1 => '1: Undefined control command'.freeze,
		:ERR2 => '2: Out of parameter range'.freeze,
		:ERR3 => '3: Busy state or no-acceptable period'.freeze,
		:ERR4 => '4: Timeout or no-acceptable period'.freeze,
		:ERR5 => '5: Wrong data length'.freeze,
		:ERRA => 'A: Password mismatch'.freeze,
		:ER401 => '401: Command cannot be executed'.freeze,
		:ER402 => '402: Invalid parameter is sent'.freeze
	}
	

	def received(data, resolve, command)		# Data is default received as a string
		logger.debug "panasonic Proj sent: #{data}"

		# This is the ready response 
		if data[0] == ' '
			@mode = data[1]
			if @mode == '1'
				@pass = "#{setting(:username) || 'admin1'}:#{setting(:password) || 'panasonic'}:#{data.strip.split(/\s+/)[-1]}"
				@pass = Digest::MD5.hexdigest(@pass)
			end

		else
			data = data[2..-1]

			# Error Response
			if data[0] == 'E'
				error = data.to_sym
				self[:last_error] = ERRORS[error]

				# Check for busy or timeout
				if error == :ERR3 || error == :ERR4
					logger.warn "Panasonic Proj busy: #{self[:last_error]}"
					return :retry
				else
					logger.error "Panasonic Proj error: #{self[:last_error]}"
					return :abort
				end
			end

                        resp = data.split(':')
			cmd = COMMANDS[resp[0].to_sym]
			val = resp[1]
				
			case cmd
			when :power_on
				self[:power] = true
			when :power_off
				self[:power] = false
			when :power_query
				self[:power] = val.to_i == 1
			when :freeze
				self[:frozen] = val.to_i == 1
			when :input
				self[:input] = INPUTS[val.to_sym]
			when :mute
				self[:mute] = val.to_i == 1
			else
				if command && command[:name] == :lamp
					ival = resp[0].to_i
					self[:power] = ival == 1 || ival == 2
					self[:warming] = ival == 1
					self[:cooling] = ival == 3
	
					if (self[:warming] || self[:cooling]) && !@check_scheduled && !self[:stable_state]
						@check_scheduled = true
						schedule.in('13s') do
							@check_scheduled = false
							logger.debug "-- checking panasonic state"
							power?({:priority => 0}) do
								state = self[:power]
								if state != self[:power_target]
									if self[:power_target] || !self[:cooling]
										power(self[:power_target])
									end
								elsif self[:power_target] && self[:cooling]
									power(self[:power_target])
								else
									self[:stable_state] = true
									switch_to(self[:input]) if self[:power_target] == On && !self[:input].nil?
								end
							end
						end
					end	
				end
			end
		end

		:success
	end

	
	protected


	def do_send(command, param = nil, options = {})
		if param.is_a? Hash
			options = param
			param = nil
		end

		# Default to the command name if name isn't set
		options[:name] = command unless options[:name]

		if param.nil?
			pj = "#{COMMANDS[command]}"
		else
			pj = "#{COMMANDS[command]}:#{param}"
		end

		if @mode == '0'
			send("00#{pj}\r", options)
		else
			send("#{@pass}00#{pj}\r", options)
		end

		nil
	end
end

