module Lumens; end


class Lumens::Dc265
	include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

	def on_load
		@mutex = Mutex.new
		on_update
	end
	
	def on_unload
	end
	
	def on_update
		defaults({
			:retries => 8,
			:delay => 300
		})
		config({
			tokenize: true,
			delimiter: "\xAF",
			indicator: "\xA0",
            encoding: "ASCII-8BIT"
		})
		
		self[:zoom_max] = 620
		self[:zoom_min] = 0
		self[:stable_state] = true
	end
	
	
	
	def connected
		do_poll
		@polling_timer = schedule.every('60s') do
			logger.debug "-- Polling Lumens DC Series Visualiser"
			do_poll
		end
	end
	
	def disconnected
		@polling_timer.cancel unless @polling_timer.nil?
		@polling_timer = nil
	end
	
	
	
	
	COMMANDS = {
		:zoom_stop => 0x10,		# p1 = 0x00
		:zoom_start => 0x11,	# p1 (00/01:Tele/Wide)
		:zoom_direct => 0x13,	# p1-LowByte, p2 highbyte (0~620)
		:lamp => 0xC1,			# p1 (00/01:Off/On)
		:power => 0xB1,			# p1 (00/01:Off/On)
		:sharp => 0xA7,		# p1 (00/01/02:Photo/Text/Gray) only photo or text
		:auto_focus => 0xA3,	# p1 = 0x01
		:frozen => 0x2C,		# p1 (00/01:Off/On)
		
		0x10 => :zoom_stop,
		0x11 => :zoom_start,
		0x13 => :zoom_direct,
		0xC1 => :lamp,
		0xB1 => :power,
		0xA7 => :sharp,
		0xA3 => :auto_focus,
		0x2C => :frozen,
		
		# Status response codes:
		0x78 => :frozen,
		0x51 => :sharp,
		0x50 => :lamp,
		0x60 => :zoom_direct,
		0xB7 => :system_status
	}
	
	
	def power(state)
		state = is_affirmative?(state)
		self[:power_target] = state
		power? do
			if state && !self[:power]		# Request to power on if off
				self[:stable_state] = false
				do_send([COMMANDS[:power], 0x01], :timeout => 15000, :delay_on_receive => 5000, :name => :power)
				
			elsif !state && self[:power]	# Request to power off if on
				self[:stable_state] = false
				do_send([COMMANDS[:power], 0x00], :timeout => 15000, :delay_on_receive => 5000, :name => :power)
				self[:frozen] = false
			end
		end
	end
	
	def power?(options = {}, &block)
		options[:emit] = block
		do_send(STATUS_CODE[:system_status], options)
	end
	
	def zoom_in
		return if self[:frozen]
		@mutex.synchronize { @focus_timer.cancel unless @focus_timer.nil? }
		do_send(COMMANDS[:zoom_start])
	end

	def zoom_out
		return if self[:frozen]
		@mutex.synchronize { @focus_timer.cancel unless @focus_timer.nil? }
		do_send([COMMANDS[:zoom_start], 0x01])
	end

	def zoom_stop
		return if self[:frozen]
		@mutex.synchronize { @focus_timer.cancel unless @focus_timer.nil? }
		do_send(COMMANDS[:zoom_stop])
	end

	def zoom(position)
		return if self[:frozen]
		@mutex.synchronize { @focus_timer.cancel unless @focus_timer.nil? }
		position = position.to_i
		
		position = 620 if position > 620
		position = 0 if position < 0
		
		low = position & 0xFF
		high = (position >> 8) & 0xFF
		
		do_send([COMMANDS[:zoom_direct], low, high], {:name => :zoom})
	end
	
	
	def lamp(power)
		return if self[:frozen]
		power = [true, 1, :on, 'on'].include?(power) ? true : false
		
		if power
			do_send([COMMANDS[:lamp], 0x01], {:name => :lamp})
		else
			do_send([COMMANDS[:lamp], 0x00], {:name => :lamp})
		end
	end
	
	
	def sharp(state)
		return if self[:frozen]
		state = [true, 1, :on, 'on'].include?(state) ? true : false
		
		if state
			do_send([COMMANDS[:sharp], 0x01], {:name => :sharp})
		else
			do_send([COMMANDS[:sharp], 0x00], {:name => :sharp})
		end
	end
	
	
	def frozen(state)
		state = [true, 1, :on, 'on'].include?(state) ? true : false
		
		if state
			do_send([COMMANDS[:frozen], 0x01], {:name => :frozen})
		else
			do_send([COMMANDS[:frozen], 0x00], {:name => :frozen})
		end
	end
	
	
	def auto_focus
		return if self[:frozen]
		@mutex.synchronize { @focus_timer.cancel unless @focus_timer.nil? }
		do_send(COMMANDS[:auto_focus], :timeout => 8000, :name => :auto_focus)
	end
	
	
	def reset
		return if self[:frozen]
		@mutex.synchronize { @focus_timer.cancel unless @focus_timer.nil? }
		power(On)
		
		RESET_CODES.each_value do |value|
			do_send(value)
		end
		
		sharp(Off)
		frozen(Off)
		lamp(On)
		zoom(0)
	end
	
	
	def received(data, reesolve, command)
		logger.debug "Lumens sent #{byte_to_hex(data)}"


		data = str_to_array(data)
		
		
		#
		# Process response
		#
		logger.debug "command was #{COMMANDS[data[0]]}"
		case COMMANDS[data[0]]
		when :zoom_stop
			#
			# A 3 second delay for zoom status and auto focus
			#
			zoom_status
			delay_focus
		when :zoom_direct
			self[:zoom] = data[1] + (data[2] << 8)
			delay_focus if COMMANDS[:zoom_direct] == data[0]	# then 3 second delay for auto focus
		when :lamp
			self[:lamp] = data[1] == 0x01
		when :power
			self[:power] = data[1] == 0x01
			if (self[:power] != self[:power_target]) && !self[:stable_state]
				power(self[:power_target])
				logger.debug "Lumens state == unstable - power resp"
			else
				self[:stable_state] = true
			end
		when :sharp
			self[:sharp] = data[1] == 0x01
		when :frozen
			self[:frozen] = data[1] == 0x01
		when :system_status
			self[:power] = data[2] == 0x01
			if (self[:power] != self[:power_target]) && !self[:stable_state]
				power(self[:power_target])
				logger.debug "Lumens state == unstable - status"
			else
				self[:stable_state] = true
			end
			# ready = data[1] == 0x01
		end
		
		
		#
		# Check for error
		# => We check afterwards as power for instance may be on when we call on
		# => The power status is sent as on with a NAK as the command did nothing
		#
		if data[3] != 0x00 && (!!!self[:frozen])
			case data[3]
			when 0x01
				logger.error "Lumens NAK error"
			when 0x10
				logger.error "Lumens IGNORE error"
				if command.present?
					command[:delay_on_receive] = 2000	# update the command
					return :abort						# retry the command
					#
					# TODO:: Call system_status(0) and check for ready every second until the command will go through
					#
				end
			else
				logger.warn "Lumens unknown error code #{data[3]}"
			end
			
			logger.error "Error on #{byte_to_hex(command[:data])}" unless command.nil?
			return :abort
		end
		
		
		return :success
	end
	
	
	
	private
	
	
	def delay_focus
		@mutex.synchronize do
			@focus_timer.cancel unless @focus_timer.nil?
			@focus_timer = schedule.in('4s') do
				auto_focus
			end
		end
	end
	
	
	
	RESET_CODES = {
		:OSD => [0x4B, 0x00],			# p1 (00/01:Off/On)	on screen display
		:digital_zoom => [0x40, 0x00],	# p1 (00/01:Disable/Enable)
		:language => [0x38, 0x00],		# p1 == 00 (english)
		:colour => [0x37, 0x00],		# p1 (00/01:Photo/Gray)
		:negative => [0x36, 0x00],		# p1 (00/01:Off/On)
		:logo => [0x47, 0x00],			# p1 (00/01:Off/On)
		:source => [0x3A, 0x01],		# p1 (00/01:PC/Live) used for reset
		:slideshow => [0x04, 0x00]		# p1 (00/01:Off/On) -- NAKs
	}
	
	
	STATUS_CODE = {
		:frozen_status => 0x78,		# p1 = 0x00
		:sharp_status => 0x51,	# p1 = 0x00
		:lamp_status => 0x50,		# p1 = 0x00
		:zoom_status => 0x60,		# p1 = 0x00
		:system_status => 0xB7
	}
	#
	# Automatically creates a callable function for each command
	#	http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
	#	http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
	#
	STATUS_CODE.each_key do |command|
		define_method command do |*args|
			priority = 99
			if args.length > 0
				priority = args[0]
			end
			
			do_send(STATUS_CODE[command], {:priority => priority, :wait => true})	# Status polling is a low priority
		end
	end
	
	
	def do_poll
		power?(:priority => 99) do
			if self[:power] == On
				frozen_status
				if not self[:frozen]
					zoom_status
					lamp_status
					sharp_status
				end
			end
		end
	end
	
	
	def do_send(command, options = {})
		#logger.debug "-- GlobalCache, sending: #{command}"
		command = [command] unless command.is_a?(Array)
		while command.length < 4
			command << 0x00
		end
		
		command = [0xA0] + command + [0xAF]
		logger.debug "requesting #{byte_to_hex(command)}"
		
		send(command, options)
	end
end