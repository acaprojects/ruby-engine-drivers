module Epson; end
module Epson::Projector; end

#
# Port: 3629
#
class Epson::Projector::EscVp21
	include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

	def on_load
		#config({
		#	tokenize: true,
		#	delimiter: ":"
		#})

		self[:power] = false
		self[:stable_state] = true  # Stable by default (allows manual on and off)
		
		# Meta data for inquiring interfaces
		self[:type] = :projector
	end

	def on_update
		
	end
	
	def connected
		# Have to init comms
		send("ESC/VP.net\x10\x03\x00\x00\x00\x00")
		do_poll
		@polling_timer = schedule.every('52s', method(:do_poll))
	end

	def disconnected
		self[:power] = false
		@polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
	end
	
	
	
	#
	# Power commands
	#
	def power(state, opt = nil)
		self[:stable_state] = false
		if is_affirmative?(state)
			self[:power_target] = On
			do_send(:PWR, :ON, {:timeout => 40000, :name => :power})
			logger.debug "-- epson Proj, requested to power on"
			do_send(:PWR, :name => :power_state)
		else
			self[:power_target] = Off
			do_send(:PWR, :OFF, {:timeout => 10000, :name => :power})
			logger.debug "-- epson Proj, requested to power off"
			do_send(:PWR, :name => :power_state)
		end
	end

	def power?(options = {}, &block)
		options[:emit] = block if block_given?
		options[:name] = :power_state
		do_send(:PWR, options)
	end
	
	
	
	#
	# Input selection
	#
	INPUTS = {
		:hdmi => 0x30 # TODO:: Might need to have a setting for configuring this
	}
	INPUTS.merge!(INPUTS.invert)
	
	
	def switch_to(input)
		input = input.to_sym
		return unless INPUTS.has_key? input
		
		do_send(:SOURCE, INPUTS[input].to_s(16), {:name => :inpt_source})
		do_send(:SOURCE, {:name => :inpt_query})
		
		logger.debug "-- epson LCD, requested to switch to: #{input}"
		
		self[:input] = input	# for a responsive UI
	end
	
	
	
	#
	# Volume commands are sent using the inpt command
	#
	def volume(vol, options = {})
        vol = vol.to_i
        vol = 0 if vol < 0
        vol = 255 if vol > 255

        do_send(:VOL, vol, options)
    end
	
	
	#
	# Mute Audio and Video
	#
	def mute
		logger.debug "-- epson Proj, requested to mute"
		do_send(:MUTE, :ON, {:name => :video_mute})	# Audio + Video
		do_send(:MUTE) # request status
	end

	def unmute
		logger.debug "-- epson Proj, requested to mute"
		do_send(:MUTE, :OFF, {:name => :video_mute})
		do_send(:MUTE)
	end
	
	
	ERRORS = {
		0 => '00: no error'.freeze,
		1 => '01: fan error'.freeze,
		3 => '03: lamp failure at power on'.freeze,
		4 => '04: high internal temperature'.freeze,
		6 => '06: lamp error'.freeze,
		7 => '07: lamp cover door open'.freeze,
		8 => '08: cinema filter error'.freeze,
		9 => '09: capacitor is disconnected'.freeze,
		10 => '0A: auto iris error'.freeze,
		11 => '0B: subsystem error'.freeze,
		12 => '0C: low air flow error'.freeze,
		13 => '0D: air flow sensor error'.freeze,
		14 => '0E: ballast power supply error'.freeze,
		15 => '0F: shutter error'.freeze,
		16 => '10: peltiert cooling error'.freeze,
		17 => '11: pump cooling error'.freeze,
		18 => '12: static iris error'.freeze,
		19 => '13: power supply unit error'.freeze,
		20 => '14: exhaust shutter error'.freeze,
		21 => '15: obstacle detection error'.freeze,
		22 => '16: IF board discernment error'.freeze
	}
	
	#
	# epson Response code
	#
	def received(data, resolve, command)		# Data is default received as a string
		logger.debug "epson Proj sent: #{data}"

		if data == ':'
			return :success
		end

		data = data.split(/=|\r:/)
		case data[0].to_sym
		when :ERR
			# Lookup error!
			if data[1].nil?
				warning = "Epson PJ sent error response"
				warning << " for #{command[:data].inspect}" if command
				logger.warn warning
				return :abort
			else
				code = data[1].to_i(16)
				self[:last_error] = ERRORS[code] || "#{data[1]}: unknown error code #{code}"
				logger.warn "Epson PJ error was #{self[:last_error]}"
				return :success
			end
		when :PWR
			state = data[1].to_i
			self[:power] = state < 3
			self[:warming] = state == 2
			self[:cooling] = state == 3
			if self[:warming] || self[:cooling]
				schedule.in('5s') do
					power?({:priority => 0})
				end
			end
			if !self[:stable_state] && self[:power_target] == self[:power]
				self[:stable_state] = true
			end

		when :MUTE
			self[:mute] = data[1] == 'ON'
		when :VOL
			self[:volume] = data[1].to_i
		when :LAMP
			self[:lamp] = data[1].to_i
		when :SOURCE
			self[:source] = INPUTS[data[1].to_i(16)] || :unknown
		end

		:success
	end

	def inspect_error
		do_send(:ERR, priority: 0)
	end
	
	
	protected
	
	
	def do_poll(*args)
		power?({:priority => 0}) do
			if self[:power]
				if self[:stable_state] == false && self[:power_target] == Off
					power(Off)
				else
					self[:stable_state] = true
					do_send(:SOURCE, {
						:name => :inpt_query,
						:priority => 0
					})
					do_send(:MUTE, {
						:name => :mute_query,
						:priority => 0
					})
					do_send(:VOL, {
						:name => :vol_query,
						:priority => 0
					})
				end
			elsif self[:stable_state] == false
				if self[:power_target] == On
					power(On)
				else
					self[:stable_state] = true
				end
			end
		end
		do_send(:LAMP, {:priority => 0})
	end

	def do_send(command, param = nil, options = {})
		if param.is_a? Hash
			options = param
			param = nil
		end

		if param.nil?
			send("#{command}?\x0D", options)
		else
			send("#{command} #{param}\x0D", options)
		end
	end
end

